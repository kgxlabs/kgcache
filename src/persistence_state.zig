const std = @import("std");
const Lock = @import("lock.zig");
const time = @import("time.zig");
const Store = @import("store/interface.zig");
const Config = @import("config.zig");

const PersistenceState = @This();

pub const BackgroundStartOutcome = enum {
    started,
    scheduled,
};

pub const StartPolicy = enum {
    immediate,
    schedule,
};

pub const StartDecision = enum {
    started,
    scheduled,
    busy,
};

pub const PendingStartError = error{
    InvalidPendingClaim,
    ChildAlreadyTracked,
};

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
    report_error: ?anyerror = null,
};

pub const AofReapResult = struct {
    status: ReapResult,
    report_error: ?anyerror = null,
};

pub const Process = struct {
    wait_pid: *const fn (std.posix.pid_t) anyerror!?u32 = waitPidSystem,
};

pub const Options = struct {
    mutual_exclusive: bool,
    process: Process = .{},
};

_lock: Lock,
// pulling out as field so we can test it without having to rely on real waitpid
_process: Process,
_kgc_in_progress: bool = false,
_aof_in_progress: bool = false,
// A request stays pending while its launch is in progress. The matching
// in_progress flag marks that it has been claimed.
_pending_kgc: bool = false,
_pending_aof: bool = false,
_mutual_exclusive: bool = false,
_in_flight_kgc_save: ?KgcBackgroundSave = null,
_in_flight_aof_rewrite: ?AofBackgroundRewrite = null,
_completed_aof_rewrite: ?AofReapResult = null,
_last_failed_save_ms: ?time.UnixMs = null,
/// Number of writes (put/remove) since the last save.
_change_count: std.atomic.Value(u64) = .init(0),
/// Timestamp of the last save, initialized to "now" at construction (not
/// 0) so a freshly-started server with no save rules matching yet doesn't
/// look like it's infinitely overdue.
_last_save_ms: std.atomic.Value(i64),

pub fn init(io: std.Io, options: Options) PersistenceState {
    return .{
        ._lock = Lock.init(io),
        ._process = options.process,
        ._mutual_exclusive = options.mutual_exclusive,
        ._last_save_ms = .init(time.nowMs(io)),
    };
}

pub fn begin(self: *PersistenceState) std.Io.Cancelable!Lock.Tx {
    return self._lock.begin();
}

pub fn beginUncancelable(self: *PersistenceState) Lock.Tx {
    return self._lock.beginUncancelable();
}

pub fn tryStartKgc(self: *PersistenceState, policy: StartPolicy) StartDecision {
    if (self._pending_kgc) {
        if (policy == .schedule) return .scheduled;
        return .busy;
    }

    if (self._kgc_in_progress) return .busy;

    if (self._mutual_exclusive and (self._aof_in_progress or self._pending_aof)) {
        if (policy == .schedule) {
            self._pending_kgc = true;
            return .scheduled;
        }
        return .busy;
    }

    self._kgc_in_progress = true;

    return .started;
}

pub fn claimPendingKgc(self: *PersistenceState) bool {
    if (!self.canDispatchPendingKgc()) return false;
    self._kgc_in_progress = true;
    return true;
}

pub fn canDispatchPendingKgc(self: *PersistenceState) bool {
    const has_pending_save = self._pending_kgc;
    const save_is_idle = !self._kgc_in_progress and self._in_flight_kgc_save == null;
    const aof_allows_start = !self._mutual_exclusive or !self._aof_in_progress;

    return has_pending_save and save_is_idle and aof_allows_start;
}

/// Register the child and release its pending reservation in one state change.
/// On error, state is unchanged and the caller must terminate and reap the new child.
pub fn completePendingKgcStart(self: *PersistenceState, save: KgcBackgroundSave) PendingStartError!void {
    if (self._in_flight_kgc_save != null) return error.ChildAlreadyTracked;
    if (!self._pending_kgc or !self._kgc_in_progress) return error.InvalidPendingClaim;
    self._pending_kgc = false;
    self.setInFlightKgcSave(save);
}

/// Leave the request queued after a launch failure before a child exists.
pub fn failPendingKgcStart(self: *PersistenceState) PendingStartError!void {
    if (self._in_flight_kgc_save != null) return error.ChildAlreadyTracked;
    if (!self._pending_kgc or !self._kgc_in_progress) return error.InvalidPendingClaim;
    self._kgc_in_progress = false;
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

pub fn tryStartAof(self: *PersistenceState, policy: StartPolicy) StartDecision {
    if (self._pending_aof) return if (policy == .schedule) .scheduled else .busy;
    if (self._aof_in_progress) return .busy;
    if (self._mutual_exclusive and (self._kgc_in_progress or self._pending_kgc)) {
        if (policy == .schedule) {
            self._pending_aof = true;
            return .scheduled;
        }
        return .busy;
    }
    self._aof_in_progress = true;
    return .started;
}

/// Call while holding a PersistenceState session after storage and journal locks are held.
pub fn claimPendingAof(self: *PersistenceState) bool {
    if (!self.canDispatchPendingAof()) return false;
    self._aof_in_progress = true;
    return true;
}

pub fn canDispatchPendingAof(self: *PersistenceState) bool {
    const has_pending_rewrite = self._pending_aof;
    const rewrite_is_idle = !self._aof_in_progress and self._in_flight_aof_rewrite == null;
    const save_allows_start = !self._mutual_exclusive or !self._kgc_in_progress;
    return has_pending_rewrite and rewrite_is_idle and save_allows_start;
}

/// Register the child and release its pending reservation in one state change.
/// On error, state is unchanged and the caller must terminate and reap the new child.
pub fn completePendingAofStart(self: *PersistenceState, rewrite: AofBackgroundRewrite) PendingStartError!void {
    if (self._in_flight_aof_rewrite != null) return error.ChildAlreadyTracked;
    if (!self._pending_aof or !self._aof_in_progress) return error.InvalidPendingClaim;
    self._pending_aof = false;
    self.setInFlightAofRewrite(rewrite);
}

/// Leave the request queued after a launch failure before a child exists.
pub fn failPendingAofStart(self: *PersistenceState) PendingStartError!void {
    if (self._in_flight_aof_rewrite != null) return error.ChildAlreadyTracked;
    if (!self._pending_aof or !self._aof_in_progress) return error.InvalidPendingClaim;
    self._aof_in_progress = false;
}

pub fn setInFlightAofRewrite(self: *PersistenceState, rewrite: AofBackgroundRewrite) void {
    self._in_flight_aof_rewrite = rewrite;
}

pub fn finishAof(self: *PersistenceState) void {
    self._completed_aof_rewrite = null;
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
    const child = self.reapPid(save.pid);
    const status = child.status;
    if (status == .running) return .{ .status = .running, .report_error = child.report_error };

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
        .report_error = child.report_error,
    };
}

const ChildResult = struct {
    status: ReapResult,
    report_error: ?anyerror = null,
};

fn reapPid(self: *PersistenceState, pid: std.posix.pid_t) ChildResult {
    const maybe_status = self._process.wait_pid(pid) catch |err| {
        return .{
            .status = if (err == error.NoChildProcess) .failed else .running,
            .report_error = err,
        };
    };

    const bits = maybe_status orelse return .{ .status = .running };

    if (!std.c.W.IFEXITED(bits)) {
        return .{ .status = .failed, .report_error = error.ChildTerminatedAbnormally };
    }

    return switch (std.c.W.EXITSTATUS(bits)) {
        0 => .{ .status = .succeeded },
        1 => .{ .status = .failed },
        else => .{ .status = .failed, .report_error = error.ChildExitedAbnormally },
    };
}

fn waitPidSystem(pid: std.posix.pid_t) anyerror!?u32 {
    var status: c_int = undefined;
    while (true) {
        const result = std.posix.system.waitpid(pid, &status, std.c.W.NOHANG);
        if (result == 0) return null;

        if (result < 0) {
            switch (std.posix.errno(result)) {
                .INTR => continue,
                .CHILD => return error.NoChildProcess,
                else => return error.Unexpected,
            }
        }

        return @bitCast(status);
    }
}

pub fn terminateAndReapChild(pid: std.posix.pid_t) void {
    std.posix.kill(pid, .KILL) catch {};
    var status: c_int = undefined;
    while (true) {
        const result = std.posix.system.waitpid(pid, &status, 0);
        if (result >= 0) return;
        if (std.posix.errno(result) != .INTR) return;
    }
}

pub fn reapAof(self: *PersistenceState) AofReapResult {
    if (self._completed_aof_rewrite) |completed| return completed;
    const rewrite = self._in_flight_aof_rewrite orelse return .{ .status = .running };
    const child = self.reapPid(rewrite.pid);
    if (child.status == .running) return .{ .status = .running, .report_error = child.report_error };

    self._in_flight_aof_rewrite = null;
    const completed: AofReapResult = .{ .status = child.status, .report_error = child.report_error };
    self._completed_aof_rewrite = completed;
    return completed;
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

test "ending a PersistenceState session allows another session to begin" {
    const testing = std.testing;
    var state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });

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

    var state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });
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
    var state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });

    {
        var tx = try state.begin();
        defer tx.end();
        try testing.expectEqual(PersistenceState.StartDecision.started, state.tryStartKgc(.immediate));
    }
    {
        var tx = try state.begin();
        defer tx.end();
        try testing.expectEqual(PersistenceState.StartDecision.busy, state.tryStartKgc(.immediate));
    }
    {
        var tx = try state.begin();
        defer tx.end();
        state.finishKgc();
    }
    {
        var tx = try state.begin();
        defer tx.end();
        try testing.expectEqual(PersistenceState.StartDecision.started, state.tryStartKgc(.immediate));
    }
}

test "bgsave cooldown uses the failure time and clears explicitly" {
    const testing = std.testing;
    var state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });
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
    var state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });

    {
        var tx = try state.begin();
        defer tx.end();
        try testing.expectEqual(PersistenceState.StartDecision.started, state.tryStartAof(.immediate));
    }
    {
        var tx = try state.begin();
        defer tx.end();
        try testing.expectEqual(PersistenceState.StartDecision.busy, state.tryStartAof(.immediate));
    }
    {
        var tx = try state.begin();
        defer tx.end();
        state.finishAof();
    }
    {
        var tx = try state.begin();
        defer tx.end();
        try testing.expectEqual(PersistenceState.StartDecision.started, state.tryStartAof(.immediate));
    }
}

test "mutual exclusion blocks kgc while aof is in progress" {
    const testing = std.testing;
    var state = PersistenceState.init(testing.io, .{ .mutual_exclusive = true });

    {
        var tx = try state.begin();
        defer tx.end();
        try testing.expectEqual(PersistenceState.StartDecision.started, state.tryStartAof(.immediate));
    }
    {
        var tx = try state.begin();
        defer tx.end();
        try testing.expectEqual(PersistenceState.StartDecision.busy, state.tryStartKgc(.immediate));
    }
    {
        var tx = try state.begin();
        defer tx.end();
        state.finishAof();
    }
    {
        var tx = try state.begin();
        defer tx.end();
        try testing.expectEqual(PersistenceState.StartDecision.started, state.tryStartKgc(.immediate));
    }

    var final = try state.begin();
    final.end();
}

test "mutual exclusion blocks aof while kgc is in progress" {
    const testing = std.testing;
    var state = PersistenceState.init(testing.io, .{ .mutual_exclusive = true });

    {
        var tx = try state.begin();
        defer tx.end();
        try testing.expectEqual(PersistenceState.StartDecision.started, state.tryStartKgc(.immediate));
    }
    {
        var tx = try state.begin();
        defer tx.end();
        try testing.expectEqual(PersistenceState.StartDecision.busy, state.tryStartAof(.immediate));
    }
    {
        var tx = try state.begin();
        defer tx.end();
        state.finishKgc();
    }
    {
        var tx = try state.begin();
        defer tx.end();
        try testing.expectEqual(PersistenceState.StartDecision.started, state.tryStartAof(.immediate));
    }

    var final = try state.begin();
    final.end();
}

test "without mutual exclusion kgc and aof can be in progress at the same time" {
    const testing = std.testing;
    var state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });

    {
        var tx = try state.begin();
        defer tx.end();
        try testing.expectEqual(PersistenceState.StartDecision.started, state.tryStartKgc(.immediate));
    }
    {
        var tx = try state.begin();
        defer tx.end();
        try testing.expectEqual(PersistenceState.StartDecision.started, state.tryStartAof(.immediate));
    }

    var final = try state.begin();
    final.end();
}

test "background start decisions reserve and restore pending work" {
    const testing = std.testing;
    const Kind = enum { kgc, aof };
    const Case = struct {
        exclusive: bool,
        active: ?Kind,
        requested: Kind,
        policy: StartPolicy,
        expected: StartDecision,
    };
    const cases = [_]Case{
        .{ .exclusive = true, .active = null, .requested = .kgc, .policy = .immediate, .expected = .started },
        .{ .exclusive = true, .active = null, .requested = .aof, .policy = .schedule, .expected = .started },
        .{ .exclusive = true, .active = .kgc, .requested = .kgc, .policy = .schedule, .expected = .busy },
        .{ .exclusive = true, .active = .aof, .requested = .aof, .policy = .schedule, .expected = .busy },
        .{ .exclusive = true, .active = .kgc, .requested = .aof, .policy = .immediate, .expected = .busy },
        .{ .exclusive = true, .active = .aof, .requested = .kgc, .policy = .immediate, .expected = .busy },
        .{ .exclusive = true, .active = .kgc, .requested = .aof, .policy = .schedule, .expected = .scheduled },
        .{ .exclusive = true, .active = .aof, .requested = .kgc, .policy = .schedule, .expected = .scheduled },
        .{ .exclusive = false, .active = .kgc, .requested = .aof, .policy = .schedule, .expected = .started },
        .{ .exclusive = false, .active = .aof, .requested = .kgc, .policy = .schedule, .expected = .started },
        .{ .exclusive = false, .active = .kgc, .requested = .kgc, .policy = .schedule, .expected = .busy },
        .{ .exclusive = false, .active = .aof, .requested = .aof, .policy = .schedule, .expected = .busy },
    };

    for (cases) |case| {
        var state = PersistenceState.init(testing.io, .{ .mutual_exclusive = case.exclusive });
        var tx = try state.begin();
        defer tx.end();

        if (case.active) |active| {
            const first = switch (active) {
                .kgc => state.tryStartKgc(.immediate),
                .aof => state.tryStartAof(.immediate),
            };
            try testing.expectEqual(StartDecision.started, first);
        }

        const decision = switch (case.requested) {
            .kgc => state.tryStartKgc(case.policy),
            .aof => state.tryStartAof(case.policy),
        };
        try testing.expectEqual(case.expected, decision);

        const pending = switch (case.requested) {
            .kgc => state._pending_kgc,
            .aof => state._pending_aof,
        };
        const expected_pending = decision == .scheduled;
        try testing.expectEqual(expected_pending, pending);
    }

    const FakeWaitPid = struct {
        fn succeeded(_: std.posix.pid_t) anyerror!?u32 {
            return 0;
        }
    };

    for ([_]Kind{ .kgc, .aof }) |requested| {
        const blocker: Kind = if (requested == .kgc) .aof else .kgc;
        var state = PersistenceState.init(testing.io, .{
            .mutual_exclusive = true,
            .process = .{ .wait_pid = FakeWaitPid.succeeded },
        });
        var tx = try state.begin();
        defer tx.end();

        switch (blocker) {
            .kgc => {
                try testing.expectEqual(StartDecision.started, state.tryStartKgc(.immediate));
                state.setInFlightKgcSave(.{ .pid = 11, .captured_change_count = 0, .origin = .manual });
            },
            .aof => {
                try testing.expectEqual(StartDecision.started, state.tryStartAof(.immediate));
                state.setInFlightAofRewrite(.{ .pid = 11, .base_seq = 1, .origin = .manual });
            },
        }

        const scheduled = switch (requested) {
            .kgc => state.tryStartKgc(.schedule),
            .aof => state.tryStartAof(.schedule),
        };
        try testing.expectEqual(StartDecision.scheduled, scheduled);
        const repeated = switch (requested) {
            .kgc => state.tryStartKgc(.schedule),
            .aof => state.tryStartAof(.schedule),
        };
        try testing.expectEqual(StartDecision.scheduled, repeated);
        const immediate_while_pending = switch (requested) {
            .kgc => state.tryStartKgc(.immediate),
            .aof => state.tryStartAof(.immediate),
        };
        try testing.expectEqual(StartDecision.busy, immediate_while_pending);
        try testing.expect(if (requested == .kgc) state._pending_kgc else state._pending_aof);
        try testing.expect(!(if (requested == .kgc) state.claimPendingKgc() else state.claimPendingAof()));

        switch (blocker) {
            .kgc => {
                try testing.expectEqual(ReapResult.succeeded, state.reapKgc(time.nowMs(testing.io)).status);
                state.finishKgc();
            },
            .aof => {
                try testing.expectEqual(ReapResult.succeeded, state.reapAof().status);
                try testing.expect(state.aofInProgress());
                try testing.expectEqual(ReapResult.succeeded, state.reapAof().status);
                state.finishAof();
            },
        }

        const blocked_by_reservation = switch (blocker) {
            .kgc => state.tryStartKgc(.immediate),
            .aof => state.tryStartAof(.immediate),
        };
        try testing.expectEqual(StartDecision.busy, blocked_by_reservation);
        const queued_behind_reservation = switch (blocker) {
            .kgc => state.tryStartKgc(.schedule),
            .aof => state.tryStartAof(.schedule),
        };
        try testing.expectEqual(StartDecision.scheduled, queued_behind_reservation);

        if (requested == .kgc) {
            try testing.expectError(error.InvalidPendingClaim, state.failPendingKgcStart());
            try testing.expectError(error.InvalidPendingClaim, state.completePendingKgcStart(.{
                .pid = 99,
                .captured_change_count = 0,
                .origin = .manual,
            }));
            try testing.expect(state._in_flight_kgc_save == null);
        } else {
            try testing.expectError(error.InvalidPendingClaim, state.failPendingAofStart());
            try testing.expectError(error.InvalidPendingClaim, state.completePendingAofStart(.{
                .pid = 99,
                .base_seq = 1,
                .origin = .manual,
            }));
            try testing.expect(state._in_flight_aof_rewrite == null);
        }
        try testing.expect(if (requested == .kgc) state._pending_kgc else state._pending_aof);
        try testing.expect(if (requested == .kgc) state.claimPendingKgc() else state.claimPendingAof());
        try testing.expect(!(if (requested == .kgc) state.claimPendingKgc() else state.claimPendingAof()));
        try testing.expect(if (requested == .kgc) state._pending_kgc else state._pending_aof);
        const repeated_while_launching = switch (requested) {
            .kgc => state.tryStartKgc(.schedule),
            .aof => state.tryStartAof(.schedule),
        };
        try testing.expectEqual(StartDecision.scheduled, repeated_while_launching);

        if (requested == .kgc) try state.failPendingKgcStart() else try state.failPendingAofStart();
        try testing.expect(if (requested == .kgc) state._pending_kgc else state._pending_aof);
        try testing.expect(if (requested == .kgc) state.claimPendingKgc() else state.claimPendingAof());

        switch (requested) {
            .kgc => {
                try state.completePendingKgcStart(.{ .pid = 12, .captured_change_count = 0, .origin = .manual });
                try testing.expect(!state._pending_kgc);
            },
            .aof => {
                try state.completePendingAofStart(.{ .pid = 12, .base_seq = 2, .origin = .manual });
                try testing.expect(!state._pending_aof);
            },
        }
        try testing.expect(!(if (blocker == .kgc) state.claimPendingKgc() else state.claimPendingAof()));

        switch (requested) {
            .kgc => {
                try testing.expectEqual(ReapResult.succeeded, state.reapKgc(time.nowMs(testing.io)).status);
                state.finishKgc();
            },
            .aof => {
                try testing.expectEqual(ReapResult.succeeded, state.reapAof().status);
                state.finishAof();
            },
        }
        try testing.expect(if (blocker == .kgc) state.claimPendingKgc() else state.claimPendingAof());
    }
}

test "invalid pending completion leaves state unchanged" {
    const testing = std.testing;
    const FakeWaitPid = struct {
        fn succeeded(_: std.posix.pid_t) anyerror!?u32 {
            return 0;
        }
    };

    for ([_]enum { kgc, aof }{ .kgc, .aof }) |kind| {
        var state = PersistenceState.init(testing.io, .{
            .mutual_exclusive = true,
            .process = .{ .wait_pid = FakeWaitPid.succeeded },
        });
        var tx = try state.begin();
        defer tx.end();

        switch (kind) {
            .kgc => {
                try testing.expectError(error.InvalidPendingClaim, state.failPendingKgcStart());
                try testing.expectError(error.InvalidPendingClaim, state.completePendingKgcStart(.{
                    .pid = 21,
                    .captured_change_count = 0,
                    .origin = .manual,
                }));
                try testing.expect(!state.kgcInProgress());
                try testing.expect(!state._pending_kgc);
                try testing.expect(state._in_flight_kgc_save == null);

                try testing.expectEqual(StartDecision.started, state.tryStartKgc(.immediate));
                state.setInFlightKgcSave(.{ .pid = 21, .captured_change_count = 0, .origin = .manual });
                try testing.expectError(error.ChildAlreadyTracked, state.completePendingKgcStart(.{
                    .pid = 23,
                    .captured_change_count = 0,
                    .origin = .manual,
                }));
                try testing.expectEqual(@as(std.posix.pid_t, 21), state._in_flight_kgc_save.?.pid);
                try testing.expectError(error.ChildAlreadyTracked, state.failPendingKgcStart());
                try testing.expectEqual(ReapResult.succeeded, state.reapKgc(time.nowMs(testing.io)).status);
                state.finishKgc();
                try testing.expect(!state.kgcInProgress());
            },
            .aof => {
                try testing.expectError(error.InvalidPendingClaim, state.failPendingAofStart());
                try testing.expectError(error.InvalidPendingClaim, state.completePendingAofStart(.{
                    .pid = 22,
                    .base_seq = 1,
                    .origin = .manual,
                }));
                try testing.expect(!state.aofInProgress());
                try testing.expect(!state._pending_aof);
                try testing.expect(state._in_flight_aof_rewrite == null);

                try testing.expectEqual(StartDecision.started, state.tryStartAof(.immediate));
                state.setInFlightAofRewrite(.{ .pid = 22, .base_seq = 1, .origin = .manual });
                try testing.expectError(error.ChildAlreadyTracked, state.completePendingAofStart(.{
                    .pid = 24,
                    .base_seq = 2,
                    .origin = .manual,
                }));
                try testing.expectEqual(@as(std.posix.pid_t, 22), state._in_flight_aof_rewrite.?.pid);
                try testing.expectError(error.ChildAlreadyTracked, state.failPendingAofStart());
                try testing.expectEqual(ReapResult.succeeded, state.reapAof().status);
                state.finishAof();
                try testing.expect(!state.aofInProgress());
            },
        }
    }
}

test "reapKgc reports running until background save completes" {
    const testing = std.testing;
    var state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });
    {
        var tx = try state.begin();
        defer tx.end();
        try testing.expectEqual(PersistenceState.StartDecision.started, state.tryStartKgc(.immediate));
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
            try testing.expectEqual(PersistenceState.StartDecision.busy, state.tryStartKgc(.immediate));
            state.finishKgc();
        }
        tx.end();
        tries += 1;
        if (tries > 10_000) return error.ChildNeverReaped;
        try testing.io.sleep(.fromMilliseconds(1), .awake);
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

test "waitpid source reaches the parent reaper without reading status" {
    const testing = std.testing;
    const FakeWaitPid = struct {
        fn wait(_: std.posix.pid_t) anyerror!?u32 {
            return error.NoChildProcess;
        }
    };

    var state = PersistenceState.init(testing.io, .{
        .mutual_exclusive = false,
        .process = .{ .wait_pid = FakeWaitPid.wait },
    });
    {
        var tx = try state.begin();
        defer tx.end();
        try testing.expectEqual(PersistenceState.StartDecision.started, state.tryStartKgc(.immediate));
        state.setInFlightKgcSave(.{ .pid = 123, .captured_change_count = 1, .origin = .manual });
        const result = state.reapKgc(time.nowMs(testing.io));
        try testing.expectEqual(ReapResult.failed, result.status);
        try testing.expectEqual(error.NoChildProcess, result.report_error.?);
        try testing.expect(result.saved_change_count == null);
    }
}

test "failed manual background save preserves cooldown and allows a later save" {
    const testing = std.testing;
    var state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });
    const retry_delay_ms = 5000;
    const failure_ms = time.nowMs(testing.io) - retry_delay_ms;
    {
        var tx = try state.begin();
        defer tx.end();
        try testing.expectEqual(PersistenceState.StartDecision.started, state.tryStartKgc(.immediate));
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

    const reap_ms = failure_ms + 100;
    var result: KgcReapResult = .{ .status = .running };
    var tries: usize = 0;
    while (result.status == .running) {
        var tx = try state.begin();
        result = state.reapKgc(reap_ms);
        if (result.status != .running) state.finishKgc();
        tx.end();
        tries += 1;
        if (tries > 10_000) return error.ChildNeverReaped;
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    try testing.expectEqual(ReapResult.failed, result.status);
    try testing.expectEqual(error.ChildExitedAbnormally, result.report_error.?);
    try testing.expect(result.saved_change_count == null);
    {
        var tx = try state.begin();
        defer tx.end();
        try testing.expect(!state.bgsaveCooldownElapsed(failure_ms, retry_delay_ms));
        try testing.expect(state.bgsaveCooldownElapsed(failure_ms + retry_delay_ms, retry_delay_ms));
        try testing.expectEqual(PersistenceState.StartDecision.started, state.tryStartKgc(.immediate));
    }
}

test "dueForSave is false with no rules configured" {
    const testing = std.testing;
    var state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });

    state.recordChange();
    try testing.expect(!state.dueForSave(time.nowMs(testing.io), &.{}));
}

test "dueForSave is false before the seconds threshold elapses even with enough changes" {
    const testing = std.testing;
    var state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });

    for (0..100) |_| state.recordChange();

    const rules = [_]Config.SaveRule{.{ .seconds = 300, .changes = 100 }};
    try testing.expect(!state.dueForSave(time.nowMs(testing.io), &rules));
}

test "dueForSave is false before enough changes even after the seconds threshold elapses" {
    const testing = std.testing;
    var state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });

    for (0..99) |_| state.recordChange();

    const rules = [_]Config.SaveRule{.{ .seconds = 300, .changes = 100 }};
    const now_ms = time.nowMs(testing.io) + 300 * 1000;
    try testing.expect(!state.dueForSave(now_ms, &rules));
}

test "dueForSave is true once both thresholds are met" {
    const testing = std.testing;
    var state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });

    for (0..100) |_| state.recordChange();

    const rules = [_]Config.SaveRule{.{ .seconds = 300, .changes = 100 }};
    const now_ms = time.nowMs(testing.io) + 300 * 1000;
    try testing.expect(state.dueForSave(now_ms, &rules));
}

test "dueForSave is true when any configured rule matches" {
    const testing = std.testing;
    var state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });

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
    var state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });

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
    var state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });

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
    var state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });
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
    var state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });

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
