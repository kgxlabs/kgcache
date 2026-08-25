const std = @import("std");
const storage = @import("storage.zig");
const store = @import("store.zig");
const PersistenceState = @import("persistence_state.zig");
const ChangeTracker = @import("change_tracker.zig");
const Config = @import("config.zig");
const expiration = @import("expiration.zig");
const time = @import("time.zig");

pub fn run(
    io: std.Io,
    allocator: std.mem.Allocator,
    data_storages: []const storage.Interface,
    persistence_state: *PersistenceState,
    change_tracker: *ChangeTracker,
    data_store: *store.Store,
    config: Config,
) !void {
    const round_duration = std.Io.Duration.fromMilliseconds(config.cron_interval_ms);
    var start: usize = 0;

    while (true) {
        try io.sleep(round_duration, .awake);
        start = try expiration.runRound(io, allocator, data_storages, start, config);

        // clean up forked child processes if any
        const finished_kgc_save = persistence_state.reapKgc();
        if (finished_kgc_save) {
            change_tracker.markSaved(time.nowMs(io));
        }
        persistence_state.reapAof();

        triggerSaveIfDue(io, change_tracker, data_store, config);
    }
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

test "a completed background save resets the change tracker once reaped, not before" {
    const testing = std.testing;
    const DefaultStorage = @import("storage/default_storage.zig");
    const NotifierStorage = @import("storage/notifier_storage.zig");
    const persistence = @import("persistence.zig");

    var backend = DefaultStorage.init(testing.io, testing.allocator);
    var change_tracker = ChangeTracker.init(testing.io);
    var notifier = NotifierStorage.init(testing.allocator, backend.storage(), null, &change_tracker, 0);
    const notified_storage = notifier.storage();

    var persistence_state = PersistenceState.init(testing.io, false);
    var kgc_backend = try persistence.KgcPersistence.init(testing.io, testing.allocator, &persistence_state, "scratch-cron-reap-reset.kgc");
    var memory_store = store.MemoryStore.init(&.{notified_storage}, kgc_backend.snapshot(), &change_tracker);
    var data_store = memory_store.store();
    defer data_store.deinit();

    try writeOneKey(&data_store);
    try testing.expect(change_tracker._dirty.load(.monotonic) > 0);

    try data_store.bgsave();

    // the parent returns immediately -- reapKgc() hasn't been called yet at
    // this point, so the dirty count from the write above must still stand.
    try testing.expect(persistence_state._kgc_in_progress);
    try testing.expect(change_tracker._dirty.load(.monotonic) > 0);

    // Same check run()'s loop body does after reapKgc(): only reset once a
    // child has actually been observed to exit, not at bgsave()'s call site.
    var tries: usize = 0;
    while (persistence_state._kgc_in_progress) {
        if (persistence_state.reapKgc()) {
            change_tracker.markSaved(time.nowMs(testing.io));
        }
        tries += 1;
        if (tries > 100_000) return error.ChildNeverReaped;
    }

    try testing.expectEqual(0, change_tracker._dirty.load(.monotonic));
}

test "a failed background save still resets the change tracker" {
    const testing = std.testing;

    var persistence_state = PersistenceState.init(testing.io, false);
    var change_tracker = ChangeTracker.init(testing.io);
    change_tracker.recordChange();

    try testing.expect(persistence_state.tryStartKgc());

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
    persistence_state.setKgcPid(pid);

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

    var tries: usize = 0;
    while (persistence_state._kgc_in_progress) {
        if (persistence_state.reapKgc()) {
            change_tracker.markSaved(time.nowMs(testing.io));
        }
        tries += 1;
        if (tries > 100_000) return error.ChildNeverReaped;
    }

    // triggered but failed -- still reset, so a persistently failing save
    // retries on the next rule match rather than every single cron tick.
    try testing.expectEqual(0, change_tracker._dirty.load(.monotonic));
}

test "triggerSaveIfDue starts a background save once writes through the real store meet the configured rule" {
    const testing = std.testing;
    const DefaultStorage = @import("storage/default_storage.zig");
    const NotifierStorage = @import("storage/notifier_storage.zig");
    const persistence = @import("persistence.zig");

    var backend = DefaultStorage.init(testing.io, testing.allocator);
    var change_tracker = ChangeTracker.init(testing.io);
    var notifier = NotifierStorage.init(testing.allocator, backend.storage(), null, &change_tracker, 0);
    const notified_storage = notifier.storage();

    var persistence_state = PersistenceState.init(testing.io, false);
    var kgc_backend = try persistence.KgcPersistence.init(testing.io, testing.allocator, &persistence_state, "scratch-cron-trigger.kgc");
    var memory_store = store.MemoryStore.init(&.{notified_storage}, kgc_backend.snapshot(), &change_tracker);
    var data_store = memory_store.store();
    defer data_store.deinit();

    try writeOneKey(&data_store);

    const config: Config = .{ .save_rules = &.{.{ .seconds = 0, .changes = 1 }} };

    triggerSaveIfDue(testing.io, &change_tracker, &data_store, config);

    // the parent returns immediately -- the flag being set proves the
    // rule match actually reached bgsave() rather than being a no-op.
    try testing.expect(persistence_state._kgc_in_progress);

    var tries: usize = 0;
    while (persistence_state._kgc_in_progress) {
        _ = persistence_state.reapKgc();
        tries += 1;
        if (tries > 100_000) return error.ChildNeverReaped;
    }
}

test "triggerSaveIfDue does nothing when writes through the real store don't meet the configured rule" {
    const testing = std.testing;
    const DefaultStorage = @import("storage/default_storage.zig");
    const NotifierStorage = @import("storage/notifier_storage.zig");
    const persistence = @import("persistence.zig");

    var backend = DefaultStorage.init(testing.io, testing.allocator);
    var change_tracker = ChangeTracker.init(testing.io);
    var notifier = NotifierStorage.init(testing.allocator, backend.storage(), null, &change_tracker, 0);
    const notified_storage = notifier.storage();

    var persistence_state = PersistenceState.init(testing.io, false);
    var kgc_backend = try persistence.KgcPersistence.init(testing.io, testing.allocator, &persistence_state, "scratch-cron-no-trigger.kgc");
    var memory_store = store.MemoryStore.init(&.{notified_storage}, kgc_backend.snapshot(), &change_tracker);
    var data_store = memory_store.store();
    defer data_store.deinit();

    // one write recorded, but the rule needs a lot more than that.
    try writeOneKey(&data_store);

    const config: Config = .{ .save_rules = &.{.{ .seconds = 300, .changes = 100 }} };

    triggerSaveIfDue(testing.io, &change_tracker, &data_store, config);

    try testing.expect(!persistence_state._kgc_in_progress);
}

test "triggerSaveIfDue does nothing when no save rules are configured" {
    const testing = std.testing;
    const DefaultStorage = @import("storage/default_storage.zig");
    const NotifierStorage = @import("storage/notifier_storage.zig");
    const persistence = @import("persistence.zig");

    var backend = DefaultStorage.init(testing.io, testing.allocator);
    var change_tracker = ChangeTracker.init(testing.io);
    var notifier = NotifierStorage.init(testing.allocator, backend.storage(), null, &change_tracker, 0);
    const notified_storage = notifier.storage();

    var persistence_state = PersistenceState.init(testing.io, false);
    var kgc_backend = try persistence.KgcPersistence.init(testing.io, testing.allocator, &persistence_state, "scratch-cron-no-rules.kgc");
    var memory_store = store.MemoryStore.init(&.{notified_storage}, kgc_backend.snapshot(), &change_tracker);
    var data_store = memory_store.store();
    defer data_store.deinit();

    try writeOneKey(&data_store);

    triggerSaveIfDue(testing.io, &change_tracker, &data_store, Config.default());

    try testing.expect(!persistence_state._kgc_in_progress);
}
