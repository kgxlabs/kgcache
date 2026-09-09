const std = @import("std");
const storage = @import("storage.zig");
const store = @import("store.zig");
const persistence = @import("persistence.zig");
const PersistenceState = @import("persistence_state.zig");
const ChangeTracker = @import("change_tracker.zig");
const Config = @import("config.zig");
const expiration = @import("expiration.zig");
const time = @import("time.zig");
const Lock = @import("lock.zig");

pub fn run(
    io: std.Io,
    allocator: std.mem.Allocator,
    data_storages: []const storage.Interface,
    persistence_state: *PersistenceState,
    change_tracker: *ChangeTracker,
    data_store: *store.Store,
    maybe_aof: ?persistence.JournalPersistence,
    config: Config,
    stop_requested: *const std.atomic.Value(bool),
) !void {
    const round_duration = std.Io.Duration.fromMilliseconds(config.cron_interval_ms);
    var start: usize = 0;

    while (!stop_requested.load(.acquire)) {
        try io.sleep(round_duration, .awake);
        if (stop_requested.load(.acquire)) return;

        start = try expiration.runRound(io, allocator, data_storages, start, config);

        // clean up forked child processes if any
        {
            var state_tx = try persistence_state.begin();
            defer state_tx.end();
            const completed_save = persistence_state.reapKgc();
            _ = finishKgcIfCompleted(io, change_tracker, persistence_state, completed_save) catch {
                const message = "kgcache: failed to account for completed background save\n";
                std.Io.File.writeStreamingAll(std.Io.File.stderr(), io, message) catch {};
            };
        }

        // clean up forked child processes and register for auto rewrite
        if (maybe_aof) |aof| {
            flushAofIfDue(io, aof);
            const aof_result = blk: {
                var state_tx = try persistence_state.begin();
                defer state_tx.end();
                break :blk persistence_state.reapAof();
            };
            finishAofIfCompleted(io, aof, aof_result);
            triggerRewriteIfDue(io, aof, persistence_state, data_store, config);
        }

        triggerSaveIfDue(io, change_tracker, data_store, config);
    }
}

/// Must be called while holding a PersistenceState session so another save
/// cannot capture a snapshot change count before this completion is accounted for.
fn finishKgcIfCompleted(
    io: std.Io,
    change_tracker: *ChangeTracker,
    persistence_state: *PersistenceState,
    result: PersistenceState.KgcReapResult,
) ChangeTracker.Error!bool {
    if (result.status == .running) return false;
    defer persistence_state.finishKgc();

    if (result.status == .succeeded) {
        try change_tracker.markSaved(result.saved_change_count.?, time.nowMs(io));
    }
    return true;
}

fn flushAofIfDue(io: std.Io, aof: persistence.JournalPersistence) void {
    var tx = aof.begin() catch return;
    defer tx.end();

    aof.flush(time.nowMs(io)) catch {
        const message = "kgcache: failed to flush AOF\n";
        std.Io.File.writeStreamingAll(std.Io.File.stderr(), io, message) catch {};
    };
}

fn finishAofIfCompleted(
    io: std.Io,
    aof: persistence.JournalPersistence,
    reap_result: PersistenceState.ReapResult,
) void {
    if (reap_result == .running) return;

    var tx = aof.begin() catch return;
    defer tx.end();

    aof.finishRewrite(reap_result) catch |err| {
        var buf: [160]u8 = undefined;
        const message = std.fmt.bufPrint(
            &buf,
            "kgcache: failed to finish AOF rewrite: {s}\n",
            .{@errorName(err)},
        ) catch "kgcache: failed to finish AOF rewrite\n";
        std.Io.File.writeStreamingAll(std.Io.File.stderr(), io, message) catch {};
    };
}

fn triggerSaveIfDue(io: std.Io, change_tracker: *ChangeTracker, data_store: *store.Store, config: Config) void {
    if (!change_tracker.dueForSave(time.nowMs(io), config.save_rules)) return;

    // A failed trigger attempt should not crash the cron loop -- it'll just get
    // re-evaluated next tick.
    data_store.bgsave() catch {
        const message = "kgcache: failed to trigger automatic background save\n";
        std.Io.File.writeStreamingAll(std.Io.File.stderr(), io, message) catch {};
    };
}

fn triggerRewriteIfDue(
    io: std.Io,
    aof: persistence.JournalPersistence,
    persistence_state: *PersistenceState,
    data_store: *store.Store,
    config: Config,
) void {
    {
        var tx = aof.begin() catch return;
        defer tx.end();
        if (!aof.dueForRewrite(config)) return;
    }

    data_store.bgrewriteaof() catch {
        // A manual client command rewrite can come in after due check and before bgRewrite call and can win the race.
        // client command takes the highest priority so that refusal is expected and must not produce one log per cron tick.
        const rewrite_running = blk: {
            var state_tx = persistence_state.begin() catch break :blk false;
            defer state_tx.end();
            break :blk persistence_state.aofInProgress();
        };
        if (!rewrite_running) {
            const message = "kgcache: failed to trigger automatic AOF rewrite\n";
            std.Io.File.writeStreamingAll(std.Io.File.stderr(), io, message) catch {};
        }
    };
}

// One write through the real Store: DefaultStorage wrapped by NotifierStorage
// (same wiring as Server.create), so `data_store.set()` reaches
// `change_tracker.recordChange()` exactly the way a real client write would,
// rather than the test poking the tracker directly.
fn writeOneKey(data_store: *store.Store) !void {
    _ = try data_store.set(.{
        .key = "foo",
        .value = "bar",
        .condition = null,
        .expires_at = null,
        .keepttl = false,
        .response = null,
    }, 0);
}

const FinishRewriteJournal = struct {
    lock: Lock,
    calls: usize = 0,
    last_result: ?PersistenceState.ReapResult = null,
    fail: bool = false,
    flush_calls: usize = 0,
    last_flush_ms: ?i64 = null,
    fail_flush: bool = false,

    fn init(io: std.Io) FinishRewriteJournal {
        return .{ .lock = Lock.init(io) };
    }

    const vtable: persistence.JournalPersistence.VTable = .{
        .prepareRecord = prepareRecord,
        .flush = flush,
        .bgRewrite = bgRewrite,
        .dueForRewrite = dueForRewrite,
        .finishRewrite = finishRewrite,
        .beginLoading = beginLoading,
        .endLoading = endLoading,
        .reconcile = reconcile,
        .deinit = deinit,
    };

    fn journal(self: *FinishRewriteJournal) persistence.JournalPersistence {
        return .{ .ptr = self, .vtable = &vtable, ._lock = &self.lock };
    }

    fn publishRecord(_: *anyopaque, _: persistence.JournalPersistence.WriteEvent) persistence.JournalPersistence.Error!void {}
    fn prepareRecord(ptr: *anyopaque, event: persistence.JournalPersistence.WriteEvent) persistence.JournalPersistence.Error!persistence.JournalPersistence.Record {
        return persistence.JournalPersistence.Record.init(ptr, event, publishRecord, abortRecord);
    }
    fn abortRecord(_: *anyopaque, _: persistence.JournalPersistence.WriteEvent) void {}
    fn flush(ptr: *anyopaque, now_ms: i64) persistence.JournalPersistence.Error!void {
        const self: *FinishRewriteJournal = @ptrCast(@alignCast(ptr));
        self.flush_calls += 1;
        self.last_flush_ms = now_ms;
        if (self.fail_flush) return error.FailedToWriteIncrFile;
    }
    fn bgRewrite(_: *anyopaque, _: []const storage.Interface) persistence.JournalPersistence.Error!void {}
    fn dueForRewrite(_: *anyopaque, _: Config) bool {
        return false;
    }

    fn finishRewrite(ptr: *anyopaque, result: PersistenceState.ReapResult) persistence.JournalPersistence.Error!void {
        const self: *FinishRewriteJournal = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        self.last_result = result;
        if (self.fail) return error.FailedToRewriteAof;
    }

    fn beginLoading(_: *anyopaque) void {}
    fn endLoading(_: *anyopaque) void {}
    fn reconcile(_: *anyopaque, _: std.Io, _: std.mem.Allocator, _: std.Io.Dir, _: []const u8, _: ?persistence.AofManifest.Manifest) persistence.JournalPersistence.Error!void {}
    fn deinit(_: *anyopaque) persistence.JournalPersistence.Error!void {}
};

test "cron flushes the AOF and swallows flush errors" {
    const testing = std.testing;
    var backend = FinishRewriteJournal.init(testing.io);

    flushAofIfDue(testing.io, backend.journal());
    try testing.expectEqual(@as(usize, 1), backend.flush_calls);
    try testing.expect(backend.last_flush_ms != null);

    backend.fail_flush = true;
    const devnull = std.c.open("/dev/null", .{ .ACCMODE = .WRONLY });
    if (devnull < 0) return error.OpenDevNullFailed;
    defer _ = std.c.close(devnull);

    const saved_stderr = std.c.dup(std.posix.STDERR_FILENO);
    if (saved_stderr < 0) return error.DupFailed;
    defer {
        _ = std.c.dup2(saved_stderr, std.posix.STDERR_FILENO);
        _ = std.c.close(saved_stderr);
    }
    _ = std.c.dup2(devnull, std.posix.STDERR_FILENO);

    flushAofIfDue(testing.io, backend.journal());
    try testing.expectEqual(@as(usize, 2), backend.flush_calls);
}

test "everysec cron flush drains buffered commands" {
    const testing = std.testing;
    const cwd = std.Io.Dir.cwd();
    const dirname = "scratch-cron-flush-everysec";
    cwd.deleteTree(testing.io, dirname) catch {};
    defer cwd.deleteTree(testing.io, dirname) catch {};

    var state = PersistenceState.init(testing.io, false);
    const config: Config = .{
        .append_dirname = dirname,
        .append_fsync = .everysec,
    };
    var backend = try persistence.AofPersistence.init(testing.io, testing.allocator, &state, config);
    defer backend.journal().deinit() catch {};

    const journal = backend.journal();
    {
        var tx = try journal.begin();
        defer tx.end();
        try journal.onWrite(.{ .remove = .{ .db_index = 0, .key = "foo" } });
    }
    flushAofIfDue(testing.io, backend.journal());

    var dir = try cwd.openDir(testing.io, dirname, .{});
    defer dir.close(testing.io);
    const contents = try dir.readFileAlloc(testing.io, "appendonly.aof.1.incr", testing.allocator, .unlimited);
    defer testing.allocator.free(contents);
    try testing.expect(std.mem.indexOf(u8, contents, "DEL") != null);
}

test "no cron flush drains buffered commands" {
    const testing = std.testing;
    const cwd = std.Io.Dir.cwd();
    const dirname = "scratch-cron-flush-no";
    cwd.deleteTree(testing.io, dirname) catch {};
    defer cwd.deleteTree(testing.io, dirname) catch {};

    var state = PersistenceState.init(testing.io, false);
    const config: Config = .{
        .append_dirname = dirname,
        .append_fsync = .no,
    };
    var backend = try persistence.AofPersistence.init(testing.io, testing.allocator, &state, config);
    defer backend.journal().deinit() catch {};

    const journal = backend.journal();
    {
        var tx = try journal.begin();
        defer tx.end();
        try journal.onWrite(.{ .remove = .{ .db_index = 0, .key = "foo" } });
    }
    flushAofIfDue(testing.io, backend.journal());

    var dir = try cwd.openDir(testing.io, dirname, .{});
    defer dir.close(testing.io);
    const contents = try dir.readFileAlloc(testing.io, "appendonly.aof.1.incr", testing.allocator, .unlimited);
    defer testing.allocator.free(contents);
    try testing.expect(std.mem.indexOf(u8, contents, "DEL") != null);
}

test "cron forwards failed AOF completion and ignores a running child" {
    const testing = std.testing;
    var backend = FinishRewriteJournal.init(testing.io);
    const journal = backend.journal();

    finishAofIfCompleted(testing.io, journal, .running);
    try testing.expectEqual(@as(usize, 0), backend.calls);

    finishAofIfCompleted(testing.io, journal, .failed);
    try testing.expectEqual(@as(usize, 1), backend.calls);
    try testing.expectEqual(PersistenceState.ReapResult.failed, backend.last_result.?);
}

test "cron swallows finishRewrite errors" {
    const testing = std.testing;
    var backend = FinishRewriteJournal.init(testing.io);
    backend.fail = true;

    const devnull = std.c.open("/dev/null", .{ .ACCMODE = .WRONLY });
    if (devnull < 0) return error.OpenDevNullFailed;
    defer _ = std.c.close(devnull);

    const saved_stderr = std.c.dup(std.posix.STDERR_FILENO);
    if (saved_stderr < 0) return error.DupFailed;
    defer {
        _ = std.c.dup2(saved_stderr, std.posix.STDERR_FILENO);
        _ = std.c.close(saved_stderr);
    }
    _ = std.c.dup2(devnull, std.posix.STDERR_FILENO);

    finishAofIfCompleted(testing.io, backend.journal(), .succeeded);

    try testing.expectEqual(@as(usize, 1), backend.calls);
    try testing.expectEqual(PersistenceState.ReapResult.succeeded, backend.last_result.?);
}

test "triggerRewriteIfDue starts a rewrite when the rule is met" {
    const testing = std.testing;
    const cwd = std.Io.Dir.cwd();
    const dirname = "scratch-cron-aof-trigger";

    cwd.deleteTree(testing.io, dirname) catch {};
    defer cwd.deleteTree(testing.io, dirname) catch {};

    var state = PersistenceState.init(testing.io, false);
    const config: Config = .{
        .append_only = true,
        .append_dirname = dirname,
        .auto_aof_rewrite_min_size = 0,
    };
    var backend = try persistence.AofPersistence.init(testing.io, testing.allocator, &state, config);
    defer backend.journal().deinit() catch {};
    const journal = backend.journal();
    var kgc_backend = try persistence.KgcPersistence.init(testing.io, testing.allocator, &state, "test.kgc");
    var change_tracker = ChangeTracker.init(testing.io);
    var memory_store = store.MemoryStore.init(testing.allocator, &.{}, kgc_backend.snapshot(), journal, &change_tracker);
    var data_store = memory_store.store();
    defer data_store.deinit();

    triggerRewriteIfDue(testing.io, journal, &state, &data_store, config);

    {
        var state_tx = try state.begin();
        defer state_tx.end();
        try testing.expect(state.aofInProgress());
    }

    var result: PersistenceState.ReapResult = .running;
    var tries: usize = 0;
    while (result == .running) {
        var state_tx = try state.begin();
        result = state.reapAof();
        state_tx.end();
        tries += 1;
        if (tries > 100_000) return error.ChildNeverReaped;
    }
    var tx = try journal.begin();
    defer tx.end();
    try journal.finishRewrite(result);
}

test "triggerRewriteIfDue does nothing when a rewrite is already running" {
    const testing = std.testing;
    const cwd = std.Io.Dir.cwd();
    const dirname = "scratch-cron-aof-running";

    cwd.deleteTree(testing.io, dirname) catch {};
    defer cwd.deleteTree(testing.io, dirname) catch {};

    var state = PersistenceState.init(testing.io, false);
    const config: Config = .{
        .append_only = true,
        .append_dirname = dirname,
        .auto_aof_rewrite_min_size = 0,
    };
    var backend = try persistence.AofPersistence.init(testing.io, testing.allocator, &state, config);
    defer backend.journal().deinit() catch {};
    var mock_store = store.MockStore.init();
    var data_store = mock_store.store();

    {
        var state_tx = try state.begin();
        defer state_tx.end();
        try testing.expect(state.tryStartAof());
    }
    defer {
        var state_tx = state.begin() catch unreachable;
        defer state_tx.end();
        state.finishAof();
    }

    triggerRewriteIfDue(testing.io, backend.journal(), &state, &data_store, config);

    var state_tx = try state.begin();
    defer state_tx.end();
    try testing.expectEqual(PersistenceState.ReapResult.running, state.reapAof());
}

test "a failed rewrite is not retried immediately and wait for delay" {
    const testing = std.testing;
    const cwd = std.Io.Dir.cwd();
    const dirname = "scratch-cron-aof-backoff";

    cwd.deleteTree(testing.io, dirname) catch {};
    defer cwd.deleteTree(testing.io, dirname) catch {};

    var state = PersistenceState.init(testing.io, false);
    const config: Config = .{
        .append_only = true,
        .append_dirname = dirname,
        .auto_aof_rewrite_min_size = 0,
    };
    var backend = try persistence.AofPersistence.init(testing.io, testing.allocator, &state, config);
    defer backend.journal().deinit() catch {};
    backend._last_rewrite_attempt_ms = time.nowMs(testing.io);
    var mock_store = store.MockStore.init();
    var data_store = mock_store.store();

    triggerRewriteIfDue(testing.io, backend.journal(), &state, &data_store, config);

    var state_tx = try state.begin();
    defer state_tx.end();
    try testing.expect(!state.aofInProgress());
    try testing.expectEqual(PersistenceState.ReapResult.running, state.reapAof());
}

test "a completed background save preserves changes made after its snapshot change count" {
    const testing = std.testing;
    const DefaultStorage = @import("storage/default_storage.zig");
    const NotifierStorage = @import("storage/notifier_storage.zig");
    const persistence_module = @import("persistence.zig");

    var backend = DefaultStorage.init(testing.io, testing.allocator);
    var change_tracker = ChangeTracker.init(testing.io);
    var notifier = NotifierStorage.init(testing.allocator, backend.storage(), null, &change_tracker, 0);
    const notified_storage = notifier.storage();

    var persistence_state = PersistenceState.init(testing.io, false);
    var kgc_backend = try persistence_module.KgcPersistence.init(testing.io, testing.allocator, &persistence_state, "scratch-cron-reap-reset.kgc");
    var memory_store = store.MemoryStore.init(testing.allocator, &.{notified_storage}, kgc_backend.snapshot(), null, &change_tracker);
    var data_store = memory_store.store();
    defer data_store.deinit();

    try writeOneKey(&data_store);
    try testing.expect(change_tracker._dirty.load(.monotonic) > 0);

    try data_store.bgsave();

    // This write happens after the child captured its snapshot change count.
    try writeOneKey(&data_store);

    // the parent returns immediately -- reapKgc() hasn't been called yet at
    // this point, so the dirty count from the write above must still stand.
    {
        var state_tx = try persistence_state.begin();
        defer state_tx.end();
        try testing.expect(persistence_state.kgcInProgress());
    }
    try testing.expect(change_tracker._dirty.load(.monotonic) > 0);

    // Same check run()'s loop body does after reapKgc(): only reset once a
    // child has actually been observed to exit, not at bgsave()'s call site.
    var reap_result: PersistenceState.KgcReapResult = .{ .status = .running };
    var tries: usize = 0;
    while (reap_result.status == .running) {
        var state_tx = try persistence_state.begin();
        reap_result = persistence_state.reapKgc();
        _ = try finishKgcIfCompleted(testing.io, &change_tracker, &persistence_state, reap_result);
        state_tx.end();
        tries += 1;
        if (tries > 100_000) return error.ChildNeverReaped;
    }

    try testing.expectEqual(1, change_tracker._dirty.load(.monotonic));
}

test "a failed background save leaves the change tracker dirty" {
    const testing = std.testing;

    var persistence_state = PersistenceState.init(testing.io, false);
    var change_tracker = ChangeTracker.init(testing.io);
    change_tracker.recordChange();

    {
        var state_tx = try persistence_state.begin();
        defer state_tx.end();
        try testing.expect(persistence_state.tryStartKgc());
    }

    const rc = std.posix.system.fork();
    const pid: std.posix.pid_t = switch (std.posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        else => |err| return std.posix.unexpectedErrno(err),
    };

    if (pid == 0) {
        _ = std.c.close(std.posix.STDIN_FILENO);
        _ = std.c.close(std.posix.STDOUT_FILENO);
        std.c._exit(7);
    }
    {
        var state_tx = try persistence_state.begin();
        defer state_tx.end();
        persistence_state.setInFlightKgcSave(.{ .pid = pid, .captured_change_count = change_tracker.captureSnapshotChangeCount() });
    }

    // reapKgc logs to the real stderr when it observes this non-zero exit --
    // exactly what this test exercises. Redirect it for the reap loop, then
    // restore it, same as persistence_state.zig's own
    // "reapKgc clears state after the child exits with a failure status" test.
    const devnull = std.c.open("/dev/null", .{ .ACCMODE = .WRONLY });
    if (devnull < 0) return error.OpenDevNullFailed;
    defer _ = std.c.close(devnull);

    const saved_stderr = std.c.dup(std.posix.STDERR_FILENO);
    if (saved_stderr < 0) return error.DupFailed;
    defer {
        _ = std.c.dup2(saved_stderr, std.posix.STDERR_FILENO);
        _ = std.c.close(saved_stderr);
    }
    _ = std.c.dup2(devnull, std.posix.STDERR_FILENO);

    var reap_result: PersistenceState.KgcReapResult = .{ .status = .running };
    var tries: usize = 0;
    while (reap_result.status == .running) {
        var state_tx = try persistence_state.begin();
        reap_result = persistence_state.reapKgc();
        _ = try finishKgcIfCompleted(testing.io, &change_tracker, &persistence_state, reap_result);
        state_tx.end();
        tries += 1;
        if (tries > 100_000) return error.ChildNeverReaped;
    }

    try testing.expectEqual(1, change_tracker._dirty.load(.monotonic));
}

test "triggerSaveIfDue starts a background save once writes through the real store meet the configured rule" {
    const testing = std.testing;
    const DefaultStorage = @import("storage/default_storage.zig");
    const NotifierStorage = @import("storage/notifier_storage.zig");
    const persistence_module = @import("persistence.zig");

    var backend = DefaultStorage.init(testing.io, testing.allocator);
    var change_tracker = ChangeTracker.init(testing.io);
    var notifier = NotifierStorage.init(testing.allocator, backend.storage(), null, &change_tracker, 0);
    const notified_storage = notifier.storage();

    var persistence_state = PersistenceState.init(testing.io, false);
    var kgc_backend = try persistence_module.KgcPersistence.init(testing.io, testing.allocator, &persistence_state, "scratch-cron-trigger.kgc");
    var memory_store = store.MemoryStore.init(testing.allocator, &.{notified_storage}, kgc_backend.snapshot(), null, &change_tracker);
    var data_store = memory_store.store();
    defer data_store.deinit();

    try writeOneKey(&data_store);

    const config: Config = .{ .save_rules = &.{.{ .seconds = 0, .changes = 1 }} };

    triggerSaveIfDue(testing.io, &change_tracker, &data_store, config);

    // the parent returns immediately -- the flag being set proves the
    // rule match actually reached bgsave() rather than being a no-op.
    {
        var state_tx = try persistence_state.begin();
        defer state_tx.end();
        try testing.expect(persistence_state.kgcInProgress());
    }

    var reap_result: PersistenceState.KgcReapResult = .{ .status = .running };
    var tries: usize = 0;
    while (reap_result.status == .running) {
        var state_tx = try persistence_state.begin();
        reap_result = persistence_state.reapKgc();
        _ = try finishKgcIfCompleted(testing.io, &change_tracker, &persistence_state, reap_result);
        state_tx.end();
        tries += 1;
        if (tries > 100_000) return error.ChildNeverReaped;
    }
}

test "triggerSaveIfDue does nothing when writes through the real store don't meet the configured rule" {
    const testing = std.testing;
    const DefaultStorage = @import("storage/default_storage.zig");
    const NotifierStorage = @import("storage/notifier_storage.zig");
    const persistence_module = @import("persistence.zig");

    var backend = DefaultStorage.init(testing.io, testing.allocator);
    var change_tracker = ChangeTracker.init(testing.io);
    var notifier = NotifierStorage.init(testing.allocator, backend.storage(), null, &change_tracker, 0);
    const notified_storage = notifier.storage();

    var persistence_state = PersistenceState.init(testing.io, false);
    var kgc_backend = try persistence_module.KgcPersistence.init(testing.io, testing.allocator, &persistence_state, "scratch-cron-no-trigger.kgc");
    var memory_store = store.MemoryStore.init(
        testing.allocator,
        &.{notified_storage},
        kgc_backend.snapshot(),
        null,
        &change_tracker,
    );
    var data_store = memory_store.store();
    defer data_store.deinit();

    // one write recorded, but the rule needs a lot more than that.
    try writeOneKey(&data_store);

    const config: Config = .{ .save_rules = &.{.{ .seconds = 300, .changes = 100 }} };

    triggerSaveIfDue(testing.io, &change_tracker, &data_store, config);

    var state_tx = try persistence_state.begin();
    defer state_tx.end();
    try testing.expect(!persistence_state.kgcInProgress());
}

test "triggerSaveIfDue does nothing when no save rules are configured" {
    const testing = std.testing;
    const DefaultStorage = @import("storage/default_storage.zig");
    const NotifierStorage = @import("storage/notifier_storage.zig");
    const persistence_module = @import("persistence.zig");

    var backend = DefaultStorage.init(testing.io, testing.allocator);
    var change_tracker = ChangeTracker.init(testing.io);
    var notifier = NotifierStorage.init(testing.allocator, backend.storage(), null, &change_tracker, 0);
    const notified_storage = notifier.storage();

    var persistence_state = PersistenceState.init(testing.io, false);
    var kgc_backend = try persistence_module.KgcPersistence.init(testing.io, testing.allocator, &persistence_state, "scratch-cron-no-rules.kgc");
    var memory_store = store.MemoryStore.init(
        testing.allocator,
        &.{notified_storage},
        kgc_backend.snapshot(),
        null,
        &change_tracker,
    );
    var data_store = memory_store.store();
    defer data_store.deinit();

    try writeOneKey(&data_store);

    triggerSaveIfDue(testing.io, &change_tracker, &data_store, Config.default());

    var state_tx = try persistence_state.begin();
    defer state_tx.end();
    try testing.expect(!persistence_state.kgcInProgress());
}
