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
