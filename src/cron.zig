const std = @import("std");
const storage = @import("storage.zig");
const store = @import("store.zig");
const persistence = @import("persistence.zig");
const PersistenceState = @import("persistence_state.zig");
const Config = @import("config.zig");
const expiration = @import("expiration.zig");
const time = @import("time.zig");
const Lock = @import("lock.zig");

pub fn run(
    io: std.Io,
    allocator: std.mem.Allocator,
    data_storages: []const storage.Interface,
    persistence_state: *PersistenceState,
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
            const completed_save = persistence_state.reapKgc(time.nowMs(io));
            _ = finishKgcIfCompleted(io, persistence_state, completed_save) catch {
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

        triggerSaveIfDue(
            io,
            data_store,
            persistence_state,
            time.nowMs(io),
            config,
        );
    }
}

/// Must be called while holding a PersistenceState session so another save
/// cannot capture a snapshot change count before this completion is accounted for.
fn finishKgcIfCompleted(
    io: std.Io,
    persistence_state: *PersistenceState,
    result: PersistenceState.KgcReapResult,
) !bool {
    if (result.status == .running) return false;
    // NOTE: this placement is intentional. We will only set in_progress => false only for completion(failed/succeeded)
    defer persistence_state.finishKgc();

    if (result.status == .succeeded) {
        try persistence_state.markSaved(result.saved_change_count.?, time.nowMs(io));
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

fn triggerSaveIfDue(
    io: std.Io,
    data_store: *store.Store,
    persistence_state: *PersistenceState,
    now_ms: time.UnixMs,
    config: Config,
) void {
    if (!persistence_state.dueForSave(now_ms, config.save_rules)) return;

    {
        var state_tx = persistence_state.begin() catch return;
        defer state_tx.end();
        if (!persistence_state.bgsaveCooldownElapsed(now_ms, config.bgsave_retry_delay_ms)) {
            return;
        }
    }

    // A failed trigger attempt should not crash the cron loop -- it'll just get
    // re-evaluated next tick.
    data_store.bgsave(.automatic) catch |err| {
        switch (err) {
            error.SaveAlreadyInProgress => {},
            else => {
                var state_tx = persistence_state.begin() catch return;
                defer state_tx.end();
                persistence_state.startBgsaveCooldown(now_ms);

                const message = "kgcache: failed to trigger automatic background save\n";
                std.Io.File.writeStreamingAll(std.Io.File.stderr(), io, message) catch {};
                return;
            },
        }
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

    data_store.bgrewriteaof(.automatic) catch {
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
// `persistence_state.recordChange()` exactly the way a real client write would,
// rather than the test poking persistence state directly.
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
    fn bgRewrite(_: *anyopaque, _: []const storage.Interface, _: store.Store.TriggerOrigin) persistence.JournalPersistence.Error!void {}
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
    var memory_store = store.MemoryStore.init(testing.allocator, &.{}, kgc_backend.snapshot(), journal);
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
        if (tries > 10_000) return error.ChildNeverReaped;
        try testing.io.sleep(.fromMilliseconds(1), .awake);
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
    var persistence_state = PersistenceState.init(testing.io, false);
    var notifier = NotifierStorage.init(testing.allocator, backend.storage(), null, &persistence_state, 0);
    const notified_storage = notifier.storage();

    var kgc_backend = try persistence_module.KgcPersistence.init(testing.io, testing.allocator, &persistence_state, "scratch-cron-reap-reset.kgc");
    var memory_store = store.MemoryStore.init(testing.allocator, &.{notified_storage}, kgc_backend.snapshot(), null);
    var data_store = memory_store.store();
    defer data_store.deinit();

    try writeOneKey(&data_store);
    try testing.expect(persistence_state.captureSnapshotChangeCount() > 0);

    try data_store.bgsave(.manual);

    // This write happens after the child captured its snapshot change count.
    try writeOneKey(&data_store);

    // the parent returns immediately -- reapKgc() hasn't been called yet at
    // this point, so the dirty count from the write above must still stand.
    {
        var state_tx = try persistence_state.begin();
        defer state_tx.end();
        try testing.expect(persistence_state.kgcInProgress());
    }
    try testing.expect(persistence_state.captureSnapshotChangeCount() > 0);

    // Same check run()'s loop body does after reapKgc(): only reset once a
    // child has actually been observed to exit, not at bgsave()'s call site.
    const reap_ms = time.nowMs(testing.io);
    var reap_result: PersistenceState.KgcReapResult = .{ .status = .running };
    var tries: usize = 0;
    while (reap_result.status == .running) {
        var state_tx = try persistence_state.begin();
        reap_result = persistence_state.reapKgc(reap_ms);
        _ = try finishKgcIfCompleted(testing.io, &persistence_state, reap_result);
        state_tx.end();
        tries += 1;
        if (tries > 10_000) return error.ChildNeverReaped;
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    }

    try testing.expectEqual(1, persistence_state.captureSnapshotChangeCount());
}

test "a failed background save leaves changes dirty" {
    const testing = std.testing;

    var persistence_state = PersistenceState.init(testing.io, false);
    persistence_state.recordChange();

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
        persistence_state.setInFlightKgcSave(.{
            .pid = pid,
            .captured_change_count = persistence_state.captureSnapshotChangeCount(),
            .origin = .automatic,
        });
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

    const failure_ms = time.nowMs(testing.io);
    var reap_result: PersistenceState.KgcReapResult = .{ .status = .running };
    var tries: usize = 0;
    while (reap_result.status == .running) {
        var state_tx = try persistence_state.begin();
        reap_result = persistence_state.reapKgc(failure_ms);
        _ = try finishKgcIfCompleted(testing.io, &persistence_state, reap_result);
        state_tx.end();
        tries += 1;
        if (tries > 10_000) return error.ChildNeverReaped;
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    }

    try testing.expectEqual(1, persistence_state.captureSnapshotChangeCount());
    {
        var state_tx = try persistence_state.begin();
        defer state_tx.end();
        try testing.expect(!persistence_state.bgsaveCooldownElapsed(failure_ms, 5000));
    }
}

test "triggerSaveIfDue starts a background save once writes through the real store meet the configured rule" {
    const testing = std.testing;
    const DefaultStorage = @import("storage/default_storage.zig");
    const NotifierStorage = @import("storage/notifier_storage.zig");
    const persistence_module = @import("persistence.zig");

    var backend = DefaultStorage.init(testing.io, testing.allocator);
    var persistence_state = PersistenceState.init(testing.io, false);
    var notifier = NotifierStorage.init(testing.allocator, backend.storage(), null, &persistence_state, 0);
    const notified_storage = notifier.storage();

    var kgc_backend = try persistence_module.KgcPersistence.init(testing.io, testing.allocator, &persistence_state, "scratch-cron-trigger.kgc");
    var memory_store = store.MemoryStore.init(testing.allocator, &.{notified_storage}, kgc_backend.snapshot(), null);
    var data_store = memory_store.store();
    defer data_store.deinit();

    try writeOneKey(&data_store);

    const config: Config = .{ .save_rules = &.{.{ .seconds = 0, .changes = 1 }} };

    triggerSaveIfDue(testing.io, &data_store, &persistence_state, time.nowMs(testing.io), config);

    // the parent returns immediately -- the flag being set proves the
    // rule match actually reached bgsave() rather than being a no-op.
    {
        var state_tx = try persistence_state.begin();
        defer state_tx.end();
        try testing.expect(persistence_state.kgcInProgress());
    }

    const reap_ms = time.nowMs(testing.io);
    var reap_result: PersistenceState.KgcReapResult = .{ .status = .running };
    var tries: usize = 0;
    while (reap_result.status == .running) {
        var state_tx = try persistence_state.begin();
        reap_result = persistence_state.reapKgc(reap_ms);
        _ = try finishKgcIfCompleted(testing.io, &persistence_state, reap_result);
        state_tx.end();
        tries += 1;
        if (tries > 10_000) return error.ChildNeverReaped;
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    }
}

test "triggerSaveIfDue does nothing when writes through the real store don't meet the configured rule" {
    const testing = std.testing;
    const DefaultStorage = @import("storage/default_storage.zig");
    const NotifierStorage = @import("storage/notifier_storage.zig");
    const persistence_module = @import("persistence.zig");

    var backend = DefaultStorage.init(testing.io, testing.allocator);
    var persistence_state = PersistenceState.init(testing.io, false);
    var notifier = NotifierStorage.init(testing.allocator, backend.storage(), null, &persistence_state, 0);
    const notified_storage = notifier.storage();

    var kgc_backend = try persistence_module.KgcPersistence.init(testing.io, testing.allocator, &persistence_state, "scratch-cron-no-trigger.kgc");
    var memory_store = store.MemoryStore.init(
        testing.allocator,
        &.{notified_storage},
        kgc_backend.snapshot(),
        null,
    );
    var data_store = memory_store.store();
    defer data_store.deinit();

    // one write recorded, but the rule needs a lot more than that.
    try writeOneKey(&data_store);

    const config: Config = .{ .save_rules = &.{.{ .seconds = 300, .changes = 100 }} };

    triggerSaveIfDue(testing.io, &data_store, &persistence_state, time.nowMs(testing.io), config);

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
    var persistence_state = PersistenceState.init(testing.io, false);
    var notifier = NotifierStorage.init(testing.allocator, backend.storage(), null, &persistence_state, 0);
    const notified_storage = notifier.storage();

    var kgc_backend = try persistence_module.KgcPersistence.init(testing.io, testing.allocator, &persistence_state, "scratch-cron-no-rules.kgc");
    var memory_store = store.MemoryStore.init(
        testing.allocator,
        &.{notified_storage},
        kgc_backend.snapshot(),
        null,
    );
    var data_store = memory_store.store();
    defer data_store.deinit();

    try writeOneKey(&data_store);

    triggerSaveIfDue(testing.io, &data_store, &persistence_state, time.nowMs(testing.io), Config.default());

    var state_tx = try persistence_state.begin();
    defer state_tx.end();
    try testing.expect(!persistence_state.kgcInProgress());
}

test "triggerSaveIfDue waits after an automatic save start failure" {
    const testing = std.testing;
    var persistence_state = PersistenceState.init(testing.io, false);
    persistence_state.recordChange();
    var mock_store = store.MockStore.init();
    mock_store.bgsave_result = error.UnableToBackgroundSaveKgc;
    var data_store = mock_store.store();
    const config: Config = .{
        .save_rules = &.{.{ .seconds = 0, .changes = 1 }},
        .bgsave_retry_delay_ms = 5000,
    };

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

    const now_ms = time.nowMs(testing.io);
    triggerSaveIfDue(testing.io, &data_store, &persistence_state, now_ms, config);
    triggerSaveIfDue(testing.io, &data_store, &persistence_state, now_ms, config);

    try testing.expectEqual(@as(usize, 1), mock_store.bgsave_calls);
}

test "triggerSaveIfDue does not start cooldown for a busy save" {
    const testing = std.testing;
    var persistence_state = PersistenceState.init(testing.io, false);
    persistence_state.recordChange();
    var mock_store = store.MockStore.init();
    mock_store.bgsave_result = error.SaveAlreadyInProgress;
    var data_store = mock_store.store();
    const config: Config = .{
        .save_rules = &.{.{ .seconds = 0, .changes = 1 }},
        .bgsave_retry_delay_ms = 5000,
    };

    const now_ms = time.nowMs(testing.io);
    triggerSaveIfDue(testing.io, &data_store, &persistence_state, now_ms, config);
    mock_store.bgsave_result = {};
    triggerSaveIfDue(testing.io, &data_store, &persistence_state, now_ms, config);

    try testing.expectEqual(@as(usize, 2), mock_store.bgsave_calls);
}

test "triggerSaveIfDue retries at the cooldown boundary without another write" {
    const testing = std.testing;
    var persistence_state = PersistenceState.init(testing.io, false);
    persistence_state.recordChange();
    const failure_ms = time.nowMs(testing.io);
    {
        var state_tx = try persistence_state.begin();
        defer state_tx.end();
        persistence_state.startBgsaveCooldown(failure_ms);
    }

    var mock_store = store.MockStore.init();
    var data_store = mock_store.store();
    const config: Config = .{
        .save_rules = &.{.{ .seconds = 0, .changes = 1 }},
        .bgsave_retry_delay_ms = 5000,
    };

    triggerSaveIfDue(testing.io, &data_store, &persistence_state, failure_ms + 4999, config);
    try testing.expectEqual(@as(usize, 0), mock_store.bgsave_calls);

    triggerSaveIfDue(testing.io, &data_store, &persistence_state, failure_ms + 5000, config);
    try testing.expectEqual(@as(usize, 1), mock_store.bgsave_calls);
}
