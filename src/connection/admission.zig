const std = @import("std");
const Lock = @import("../lock.zig");
const CapacityCalculator = @import("capacity.zig");
const ServerBudget = @import("server_budget.zig");

const Admission = @This();

pub const Lifecycle = enum { not_started, running, stopping, failed, closed };

pub const Limits = struct {
    queue_limit: usize,
    connection_limit: usize,
    unfinished_setup_limit: usize,
    buffer_limit_bytes: usize,
    initial_buffer_bytes: usize,

    pub fn validate(self: Limits) error{InvalidAdmissionLimits}!void {
        _ = self;
        @panic("Admission.Limits.validate is not implemented");
    }
};

pub const PendingSession = struct {
    id: u64,
    stream: std.Io.net.Stream,
    enqueued_at_ns: std.Io.Timestamp,
    server_reservation: ServerBudget.Reservation,
    worker_buffer_charge: usize,
};

pub const EnqueueError = CapacityCalculator.AdmissionError || error{InvalidRegistrationState};

_allocator: std.mem.Allocator,
_lock: Lock,
_limits: Limits,
_lifecycle: Lifecycle = .not_started,
_pending: []PendingSession,
_head: usize = 0,
_len: usize = 0,
_initializing: usize = 0,
_owned: usize = 0,
_reserved_buffer_bytes: usize = 0,

pub fn init(io: std.Io, allocator: std.mem.Allocator, limits: Limits) !Admission {
    try limits.validate();
    return .{
        ._allocator = allocator,
        ._lock = Lock.init(io),
        ._limits = limits,
        ._pending = try allocator.alloc(PendingSession, limits.queue_limit),
    };
}

// Call after all owned connections have been settled and the thread has joined.
pub fn deinit(self: *Admission) void {
    _ = self;
    @panic("Admission.deinit is not implemented");
}

pub fn snapshot(self: *Admission) CapacityCalculator.AdmissionView {
    var tx = self._lock.beginUncancelable();
    defer tx.end();
    return self.snapshotLocked();
}

fn snapshotLocked(self: *const Admission) CapacityCalculator.AdmissionView {
    return .{
        .accepting = self._lifecycle == .running,
        .queued = self._len,
        .oldest_enqueued_at_ns = if (self._len == 0) null else self._pending[self._head].enqueued_at_ns,
        .initializing = self._initializing,
        .owned = self._owned,
        .reserved_buffer_bytes = self._reserved_buffer_bytes,
        .queue_limit = self._limits.queue_limit,
        .connection_limit = self._limits.connection_limit,
        .unfinished_setup_limit = self._limits.unfinished_setup_limit,
        .buffer_limit_bytes = self._limits.buffer_limit_bytes,
        .initial_buffer_bytes = self._limits.initial_buffer_bytes,
    };
}

// Recheck CapacityCalculator.checkHardLimits under the queue/count lock.
// Success consumes pending. Rejection leaves pending and all counts unchanged.
pub fn enqueue(self: *Admission, pending: *?PendingSession, now_ns: std.Io.Timestamp) EnqueueError!void {
    const entry = pending.* orelse return error.InvalidRegistrationState;
    var tx = self._lock.beginUncancelable();
    defer tx.end();
    if (CapacityCalculator.checkHardLimits(self.snapshotLocked())) |err| return err;
    self.commitEnqueueLocked(entry, now_ns);
    pending.* = null;
}

// No allocation or callback. Commit the entry and resource counts together.
fn commitEnqueueLocked(self: *Admission, entry: PendingSession, now_ns: std.Io.Timestamp) void {
    _ = .{ self, entry, now_ns };
    @panic("Admission.commitEnqueueLocked is not implemented");
}

// Queue removal and initializing increment must happen in the same transaction.
pub fn takeForSetup(self: *Admission) ?PendingSession {
    _ = self;
    @panic("Admission.takeForSetup is not implemented");
}

pub fn finishSetup(self: *Admission) void {
    _ = self;
    @panic("Admission.finishSetup is not implemented");
}

// Shutdown removal does not start setup or increase initializing.
pub fn takeForClose(self: *Admission) ?PendingSession {
    _ = self;
    @panic("Admission.takeForClose is not implemented");
}

pub fn releaseOwned(self: *Admission, buffer_bytes: usize) void {
    _ = .{ self, buffer_bytes };
    @panic("Admission.releaseOwned is not implemented");
}

pub fn tryReserveBuffer(self: *Admission, bytes: usize) bool {
    _ = .{ self, bytes };
    @panic("Admission.tryReserveBuffer is not implemented");
}

pub fn releaseBuffer(self: *Admission, bytes: usize) void {
    _ = .{ self, bytes };
    @panic("Admission.releaseBuffer is not implemented");
}

pub fn lifecycle(self: *Admission) Lifecycle {
    _ = self;
    @panic("Admission.lifecycle is not implemented");
}

// Return false if stop or failure won before startup completed.
pub fn markRunning(self: *Admission) bool {
    _ = self;
    @panic("Admission.markRunning is not implemented");
}

pub fn requestStop(self: *Admission) void {
    _ = self;
    @panic("Admission.requestStop is not implemented");
}

// Preserve a closed state. Repeated failure reports must not reopen admission.
pub fn markFailed(self: *Admission) void {
    _ = self;
    @panic("Admission.markFailed is not implemented");
}

pub fn markClosed(self: *Admission) void {
    _ = self;
    @panic("Admission.markClosed is not implemented");
}
