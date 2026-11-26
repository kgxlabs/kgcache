const std = @import("std");
const CapacityCalculator = @import("../capacity.zig");

const WorkerSelector = @This();

pub const max_workers: usize = 128;
pub const WorkerId = u16;
pub const SelectionError = error{InvalidCapacityAssessment};

// The manager owns workers. IDs stay stable while a worker is registered.
// Callbacks run synchronously and must not call back into the selector.
pub const Worker = struct {
    id: WorkerId,
    ptr: *anyopaque,
    assess_capacity: *const fn (*anyopaque, std.Io.Timestamp) CapacityCalculator.Assessment,
};

// Owns a bounded candidate snapshot. It borrows no worker pointers.
pub const Selection = struct {
    pub const Candidate = struct {
        id: WorkerId,
        pressure: f64,
        tie_rank: usize,
    };

    candidates: [max_workers]Candidate = undefined,
    len: usize = 0,
    _next_index: usize = 0,

    pub fn next(self: *Selection) ?WorkerId {
        if (self._next_index == self.len) return null;
        const candidate = self.candidates[self._next_index];
        self._next_index += 1;
        return candidate.id;
    }
};

// This handle borrows its implementation at a stable address.
ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    addWorker: *const fn (*anyopaque, Worker) anyerror!void,
    removeWorker: *const fn (*anyopaque, WorkerId) void,
    selection: *const fn (*anyopaque, std.Io.Timestamp) SelectionError!Selection,
    deinit: *const fn (*anyopaque) void,
};

// Success borrows the worker until removeWorker returns. Failure changes nothing.
pub fn addWorker(self: WorkerSelector, worker: Worker) !void {
    return self.vtable.addWorker(self.ptr, worker);
}

pub fn removeWorker(self: WorkerSelector, worker_id: WorkerId) void {
    self.vtable.removeWorker(self.ptr, worker_id);
}

// Read fresh assessments for each selection. Lower pressure comes first.
// Refused workers are absent. Later selections refresh their assessments.
// Reject an allowed score that is negative or nonfinite.
pub fn selection(self: WorkerSelector, now_ns: std.Io.Timestamp) SelectionError!Selection {
    return self.vtable.selection(self.ptr, now_ns);
}

pub fn deinit(self: WorkerSelector) void {
    self.vtable.deinit(self.ptr);
}
