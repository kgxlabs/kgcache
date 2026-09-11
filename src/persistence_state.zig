const std = @import("std");
const Lock = @import("lock.zig");
const time = @import("time.zig");
const Store = @import("store/interface.zig");
const Config = @import("config.zig");

const PersistenceState = @This();

pub const ReapResult = enum {
    running,
    succeeded,
    failed,
};

pub const KgcBackgroundSave = struct {
    pid: std.posix.pid_t,
    captured_change_count: u64,
    origin: Store.TriggerOrigin,
};

pub const AofBackgroundRewrite = struct {
    pid: std.posix.pid_t,
    base_seq: u32,
    origin: Store.TriggerOrigin,
};

pub const KgcReapResult = struct {
    status: ReapResult,
    saved_change_count: ?u64 = null,
    origin: ?Store.TriggerOrigin = null,
};

_io: std.Io,
_lock: Lock,
_kgc_in_progress: bool = false,
_aof_in_progress: bool = false,
_mutual_exclusive: bool = false,
_in_flight_kgc_save: ?KgcBackgroundSave = null,
_in_flight_aof_rewrite: ?AofBackgroundRewrite = null,
_last_failed_save_ms: ?time.UnixMs = null,
/// Number of writes (put/remove) since the last save.
_change_count: std.atomic.Value(u64) = .init(0),
/// Timestamp of the last save, initialized to "now" at construction (not
/// 0) so a freshly-started server with no save rules matching yet doesn't
/// look like it's infinitely overdue.
_last_save_ms: std.atomic.Value(i64),

pub fn init(io: std.Io, mutual_exclusive: bool) PersistenceState {
    return .{
        ._io = io,
        ._lock = Lock.init(io),
        ._mutual_exclusive = mutual_exclusive,
        ._last_save_ms = .init(time.nowMs(io)),
    };
}

pub fn begin(self: *PersistenceState) std.Io.Cancelable!Lock.Tx {
    return self._lock.begin();
}

pub fn beginUncancelable(self: *PersistenceState) Lock.Tx {
    return self._lock.beginUncancelable();
}

pub fn tryStartKgc(self: *PersistenceState) bool {
    if (self._kgc_in_progress) return false;
    if (self._mutual_exclusive and self._aof_in_progress) return false;
    self._kgc_in_progress = true;
    return true;
}

pub fn setInFlightKgcSave(self: *PersistenceState, save: KgcBackgroundSave) void {
    self._in_flight_kgc_save = save;
}

pub fn finishKgc(self: *PersistenceState) void {
    self._kgc_in_progress = false;
}

pub fn startBgsaveCooldown(self: *PersistenceState, now_ms: time.UnixMs) void {
    self._last_failed_save_ms = now_ms;
}

pub fn clearBgsaveCooldown(self: *PersistenceState) void {
    self._last_failed_save_ms = null;
}

pub fn bgsaveCooldownElapsed(self: *PersistenceState, now_ms: time.UnixMs, retry_delay_ms: i64) bool {
    const started_ms = self._last_failed_save_ms orelse return true;
    if (now_ms < started_ms) return false;
    return now_ms - started_ms >= retry_delay_ms;
}

pub fn tryStartAof(self: *PersistenceState) bool {
    if (self._aof_in_progress) return false;
    if (self._mutual_exclusive and self._kgc_in_progress) return false;
    self._aof_in_progress = true;
    return true;
}

pub fn setInFlightAofRewrite(self: *PersistenceState, rewrite: AofBackgroundRewrite) void {
    self._in_flight_aof_rewrite = rewrite;
}

pub fn finishAof(self: *PersistenceState) void {
    self._aof_in_progress = false;
}

pub fn aofInProgress(self: *PersistenceState) bool {
    return self._aof_in_progress;
}

pub fn kgcInProgress(self: *PersistenceState) bool {
    return self._kgc_in_progress;
}

pub fn reapKgc(self: *PersistenceState, now_ms: time.UnixMs) KgcReapResult {
    const save = self._in_flight_kgc_save orelse return .{ .status = .running };
    const status = self.reapPid("kgc", save.pid);
    if (status == .running) return .{ .status = .running };

    // only start cooldown if failed and started by cron
    if (status == .failed and save.origin == .automatic) {
        self.startBgsaveCooldown(now_ms);
    } else if (status == .succeeded) {
        self.clearBgsaveCooldown();
    }

    self._in_flight_kgc_save = null;
    const saved_change_count = if (status == .succeeded) save.captured_change_count else null;

    return .{
        .status = status,
        .saved_change_count = saved_change_count,
        .origin = save.origin,
    };
}

pub fn reapAof(self: *PersistenceState) ReapResult {
    const rewrite = self._in_flight_aof_rewrite orelse return .running;
    const status = self.reapPid("aof", rewrite.pid);
    if (status == .running) return .running;

    self._in_flight_aof_rewrite = null;
    self._aof_in_progress = false;
    return status;
}

pub fn recordChange(self: *PersistenceState) void {
    _ = self._change_count.fetchAdd(1, .monotonic);
}

pub fn captureSnapshotChangeCount(self: *PersistenceState) u64 {
    return self._change_count.load(.monotonic);
}

/// Returns true if ANY rule's condition is met
/// rules are OR'd together,
pub fn dueForSave(self: *PersistenceState, now_ms: i64, rules: []const Config.SaveRule) bool {
    const dirty = self._change_count.load(.monotonic);
    const last_save_ms = self._last_save_ms.load(.monotonic);
    const elapsed_seconds = @divFloor(now_ms - last_save_ms, 1000);

    for (rules) |rule| {
        if (elapsed_seconds >= rule.seconds and dirty >= rule.changes) return true;
    }
    return false;
}

/// Marks only the changes represented by a completed snapshot as saved.
/// Changes recorded after the snapshot change count was captured remain dirty.
pub fn markSaved(self: *PersistenceState, saved_change_count: u64, now_ms: i64) !void {
    const current_change_count = self._change_count.load(.monotonic);
    if (current_change_count < saved_change_count) return error.InvalidSavedChangeCount;

    _ = self._change_count.fetchSub(saved_change_count, .monotonic);
    self._last_save_ms.store(now_ms, .monotonic);
}

// A completed child is reported exactly once. With no pid there is no
// completion event, so callers receive .running and do no follow-up work.
fn reapPid(self: *PersistenceState, name: []const u8, pid: std.posix.pid_t) ReapResult {
    var status: c_int = undefined;
    const r = std.posix.system.waitpid(pid, &status, std.c.W.NOHANG);
    // Child porcess is still running
    if (r == 0) return .running;

    const status_bits: u32 = @bitCast(status);
    // Only a normal zero exit proves the child completed its persistence
    // work. A non-zero exit or signal termination must never publish output.
    if (!std.c.W.IFEXITED(status_bits) or std.c.W.EXITSTATUS(status_bits) != 0) {
        var buf: [128]u8 = undefined;
        const message = if (std.c.W.IFEXITED(status_bits))
            std.fmt.bufPrint(
                &buf,
                "kgcache: {s} background save child exited with status {d}\n",
                .{ name, std.c.W.EXITSTATUS(status_bits) },
            ) catch "kgcache: background save child exited with a failure status\n"
        else
            std.fmt.bufPrint(
                &buf,
                "kgcache: {s} background save child terminated abnormally\n",
                .{name},
            ) catch "kgcache: background save child terminated abnormally\n";

        std.Io.File.writeStreamingAll(std.Io.File.stderr(), self._io, message) catch {};
        return .failed;
    }

    return .succeeded;
}

test "ending a PersistenceState session allows another session to begin" {
    const testing = std.testing;
    var state = PersistenceState.init(testing.io, false);

    var first = try state.begin();
    first.end();

    var second = try state.begin();
    second.end();
}

test "PersistenceState begin serializes two concurrent callers" {
    const testing = std.testing;
    const Context = struct {
        state: *PersistenceState,
        attempting: std.atomic.Value(bool) = .init(false),
        entered: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            self.attempting.store(true, .release);
            var tx = self.state.begin() catch unreachable;
            self.entered.store(true, .release);
            tx.end();
        }
    };

    var state = PersistenceState.init(testing.io, false);
    var first = try state.begin();
    var context: Context = .{ .state = &state };
    const thread = try std.Thread.spawn(.{}, Context.run, .{&context});

    while (!context.attempting.load(.acquire)) std.atomic.spinLoopHint();
    try testing.expect(!context.entered.load(.acquire));

    first.end();
    thread.join();
    try testing.expect(context.entered.load(.acquire));
}

test "tryStartKgc blocks a second start until finishKgc releases it" {
    const testing = std.testing;
    var state = PersistenceState.init(testing.io, false);

    {
        var tx = try state.begin();
        defer tx.end();
        try testing.expect(state.tryStartKgc());
    }
    {
        var tx = try state.begin();
        defer tx.end();
        try testing.expect(!state.tryStartKgc());
    }
    {
        var tx = try state.begin();
        defer tx.end();
        state.finishKgc();
    }
    {
        var tx = try state.begin();
        defer tx.end();
        try testing.expect(state.tryStartKgc());
    }
}

test "bgsave cooldown uses the failure time and clears explicitly" {
    const testing = std.testing;
    var state = PersistenceState.init(testing.io, false);
    var tx = try state.begin();
    defer tx.end();
    const failure_ms = time.nowMs(testing.io);

    try testing.expect(state.bgsaveCooldownElapsed(failure_ms, 500));

    state.startBgsaveCooldown(failure_ms);
    try testing.expect(!state.bgsaveCooldownElapsed(failure_ms + 499, 500));
    try testing.expect(state.bgsaveCooldownElapsed(failure_ms + 500, 500));
    try testing.expect(state.bgsaveCooldownElapsed(failure_ms, 0));
    try testing.expect(!state.bgsaveCooldownElapsed(failure_ms - 1, 500));

    state.clearBgsaveCooldown();
    try testing.expect(state.bgsaveCooldownElapsed(failure_ms - 1, 500));
}

test "tryStartAof blocks a second start until finishAof releases it" {
    const testing = std.testing;
    var state = PersistenceState.init(testing.io, false);

    {
        var tx = try state.begin();
        defer tx.end();
        try testing.expect(state.tryStartAof());
    }
    {
        var tx = try state.begin();
        defer tx.end();
        try testing.expect(!state.tryStartAof());
    }
    {
        var tx = try state.begin();
        defer tx.end();
        state.finishAof();
    }
    {
        var tx = try state.begin();
        defer tx.end();
        try testing.expect(state.tryStartAof());
    }
}

test "mutual exclusion blocks kgc while aof is in progress" {
    const testing = std.testing;
    var state = PersistenceState.init(testing.io, true);

    {
        var tx = try state.begin();
        defer tx.end();
        try testing.expect(state.tryStartAof());
    }
    {
        var tx = try state.begin();
        defer tx.end();
        try testing.expect(!state.tryStartKgc());
    }
    {
        var tx = try state.begin();
        defer tx.end();
        state.finishAof();
    }
    {
        var tx = try state.begin();
        defer tx.end();
        try testing.expect(state.tryStartKgc());
    }

    var final = try state.begin();
    final.end();
}

test "mutual exclusion blocks aof while kgc is in progress" {
    const testing = std.testing;
    var state = PersistenceState.init(testing.io, true);

    {
        var tx = try state.begin();
        defer tx.end();
        try testing.expect(state.tryStartKgc());
    }
    {
        var tx = try state.begin();
        defer tx.end();
        try testing.expect(!state.tryStartAof());
    }
    {
        var tx = try state.begin();
        defer tx.end();
        state.finishKgc();
    }
    {
        var tx = try state.begin();
        defer tx.end();
        try testing.expect(state.tryStartAof());
    }

    var final = try state.begin();
    final.end();
}

test "without mutual exclusion kgc and aof can be in progress at the same time" {
    const testing = std.testing;
    var state = PersistenceState.init(testing.io, false);

    {
        var tx = try state.begin();
        defer tx.end();
        try testing.expect(state.tryStartKgc());
    }
    {
        var tx = try state.begin();
        defer tx.end();
        try testing.expect(state.tryStartAof());
    }

    var final = try state.begin();
    final.end();
}

test "reapKgc reports running until background save completes" {
    const testing = std.testing;
    var state = PersistenceState.init(testing.io, false);
    {
        var tx = try state.begin();
        defer tx.end();
        try testing.expect(state.tryStartKgc());
    }

    // A pipe lets the parent control exactly when the forked child exits,
    // instead of racing a real timing window.
    var fds: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.PipeFailed;

    const rc = std.posix.system.fork();
    const pid: std.posix.pid_t = switch (std.posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        else => |err| return std.posix.unexpectedErrno(err),
    };

    if (pid == 0) {
        // Close inherited stdin/stdout so this test child doesn't keep a
        // duplicate of the build system's IPC channel open under `zig build test`.
        _ = std.c.close(std.posix.STDIN_FILENO);
        _ = std.c.close(std.posix.STDOUT_FILENO);

        _ = std.c.close(fds[1]);
        var byte: [1]u8 = undefined;
        _ = std.c.read(fds[0], &byte, 1);
        _ = std.c.close(fds[0]);
        std.c._exit(0);
    }
    _ = std.c.close(fds[0]);
    const failure_ms = time.nowMs(testing.io);
    {
        var tx = try state.begin();
        defer tx.end();
        state.startBgsaveCooldown(failure_ms);
        state.setInFlightKgcSave(.{ .pid = pid, .captured_change_count = 17, .origin = .manual });
    }
    {
        var tx = try state.begin();
        defer tx.end();
        try testing.expectEqual(ReapResult.running, state.reapKgc(failure_ms).status);
        try testing.expect(state.kgcInProgress());
    }

    var byte: [1]u8 = .{1};
    _ = std.c.write(fds[1], &byte, 1);
    _ = std.c.close(fds[1]);

    var result: KgcReapResult = .{ .status = .running };
    var tries: usize = 0;
    while (result.status == .running) {
        var tx = try state.begin();
        result = state.reapKgc(failure_ms);
        if (result.status != .running) {
            try testing.expect(state.kgcInProgress());
            try testing.expect(!state.tryStartKgc());
            state.finishKgc();
        }
        tx.end();
        tries += 1;
        if (tries > 100_000) return error.ChildNeverReaped;
    }
    try testing.expectEqual(ReapResult.succeeded, result.status);
    try testing.expectEqual(17, result.saved_change_count.?);
    {
        var tx = try state.begin();
        defer tx.end();
        try testing.expect(!state.kgcInProgress());
        try testing.expect(state.bgsaveCooldownElapsed(failure_ms, 5000));
    }
}

test "failed manual background save preserves cooldown and allows a later save" {
    const testing = std.testing;
    var state = PersistenceState.init(testing.io, false);
    const retry_delay_ms = 5000;
    const failure_ms = time.nowMs(testing.io) - retry_delay_ms;
    {
        var tx = try state.begin();
        defer tx.end();
        try testing.expect(state.tryStartKgc());
        state.startBgsaveCooldown(failure_ms);
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
        var tx = try state.begin();
        defer tx.end();
        state.setInFlightKgcSave(.{ .pid = pid, .captured_change_count = 23, .origin = .manual });
    }

    // reapKgc logs to the real stderr when it observes a non-zero exit --
    // exactly what this test exercises. Left alone, that write lands in the
    // test binary's own stderr, and `zig build test` flags an otherwise
    // fully-passing run as a "failed command" because of it. Redirect
    // stderr to /dev/null only for the reap loop, then restore it, so the
    // logging code still runs for real without polluting captured output.
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

    const reap_ms = failure_ms + 100;
    var result: KgcReapResult = .{ .status = .running };
    var tries: usize = 0;
    while (result.status == .running) {
        var tx = try state.begin();
        result = state.reapKgc(reap_ms);
        if (result.status != .running) state.finishKgc();
        tx.end();
        tries += 1;
        if (tries > 100_000) return error.ChildNeverReaped;
    }
    try testing.expectEqual(ReapResult.failed, result.status);
    try testing.expect(result.saved_change_count == null);
    {
        var tx = try state.begin();
        defer tx.end();
        try testing.expect(!state.bgsaveCooldownElapsed(failure_ms, retry_delay_ms));
        try testing.expect(state.bgsaveCooldownElapsed(failure_ms + retry_delay_ms, retry_delay_ms));
        try testing.expect(state.tryStartKgc());
    }
}

test "dueForSave is false with no rules configured" {
    const testing = std.testing;
    var state = PersistenceState.init(testing.io, false);

    state.recordChange();
    try testing.expect(!state.dueForSave(time.nowMs(testing.io), &.{}));
}

test "dueForSave is false before the seconds threshold elapses even with enough changes" {
    const testing = std.testing;
    var state = PersistenceState.init(testing.io, false);

    for (0..100) |_| state.recordChange();

    const rules = [_]Config.SaveRule{.{ .seconds = 300, .changes = 100 }};
    try testing.expect(!state.dueForSave(time.nowMs(testing.io), &rules));
}

test "dueForSave is false before enough changes even after the seconds threshold elapses" {
    const testing = std.testing;
    var state = PersistenceState.init(testing.io, false);

    for (0..99) |_| state.recordChange();

    const rules = [_]Config.SaveRule{.{ .seconds = 300, .changes = 100 }};
    const now_ms = time.nowMs(testing.io) + 300 * 1000;
    try testing.expect(!state.dueForSave(now_ms, &rules));
}

test "dueForSave is true once both thresholds are met" {
    const testing = std.testing;
    var state = PersistenceState.init(testing.io, false);

    for (0..100) |_| state.recordChange();

    const rules = [_]Config.SaveRule{.{ .seconds = 300, .changes = 100 }};
    const now_ms = time.nowMs(testing.io) + 300 * 1000;
    try testing.expect(state.dueForSave(now_ms, &rules));
}

test "dueForSave is true when any configured rule matches" {
    const testing = std.testing;
    var state = PersistenceState.init(testing.io, false);

    for (0..5) |_| state.recordChange();

    const rules = [_]Config.SaveRule{
        .{ .seconds = 900, .changes = 10_000 },
        .{ .seconds = 300, .changes = 10_000 },
        .{ .seconds = 60, .changes = 1 },
    };
    const now_ms = time.nowMs(testing.io) + 60 * 1000;
    try testing.expect(state.dueForSave(now_ms, &rules));
}

test "markSaved resets the change count and last-save time" {
    const testing = std.testing;
    var state = PersistenceState.init(testing.io, false);

    for (0..100) |_| state.recordChange();

    const rules = [_]Config.SaveRule{.{ .seconds = 300, .changes = 100 }};
    const now_ms = time.nowMs(testing.io) + 300 * 1000;
    try testing.expect(state.dueForSave(now_ms, &rules));

    {
        var tx = try state.begin();
        defer tx.end();
        try state.markSaved(state.captureSnapshotChangeCount(), now_ms);
    }

    try testing.expect(!state.dueForSave(now_ms, &rules));
}

test "markSaved preserves changes recorded after capture" {
    const testing = std.testing;
    var state = PersistenceState.init(testing.io, false);

    for (0..3) |_| state.recordChange();
    const snapshot_change_count = state.captureSnapshotChangeCount();
    for (0..2) |_| state.recordChange();

    {
        var tx = try state.begin();
        defer tx.end();
        try state.markSaved(snapshot_change_count, time.nowMs(testing.io));
    }

    try testing.expectEqual(2, state.captureSnapshotChangeCount());
}

test "markSaved rejects a count greater than the current change count" {
    const testing = std.testing;
    var state = PersistenceState.init(testing.io, false);
    state.recordChange();

    {
        var tx = try state.begin();
        defer tx.end();
        try testing.expectError(
            error.InvalidSavedChangeCount,
            state.markSaved(2, time.nowMs(testing.io)),
        );
    }

    try testing.expectEqual(1, state.captureSnapshotChangeCount());
}

test "concurrent recordChange calls are never lost" {
    const testing = std.testing;
    var state = PersistenceState.init(testing.io, false);

    const thread_count = 8;
    const increments_per_thread = 10_000;

    const worker = struct {
        fn run(persistence_state: *PersistenceState) void {
            for (0..increments_per_thread) |_| persistence_state.recordChange();
        }
    }.run;

    var threads: [thread_count]std.Thread = undefined;
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, worker, .{&state});
    }
    for (threads) |thread| thread.join();

    try testing.expectEqual(
        @as(u64, thread_count * increments_per_thread),
        state.captureSnapshotChangeCount(),
    );
}
