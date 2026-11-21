const std = @import("std");

const WorkerSelector = @This();

pub const max_workers: usize = 128;
pub const WorkerId = u16;
pub const ExcludedWorkers = std.StaticBitSet(max_workers);

// The manager owns workers. IDs stay stable while a worker is registered.
// Capacity callbacks must be thread-safe and must not call the selector.
pub const Worker = struct {
    id: WorkerId,
    ptr: *anyopaque,
    available_capacity: *const fn (*anyopaque) usize,
};

// This handle borrows its implementation. Workers must stop using it before
// the implementation is destroyed. Implementations synchronize shared state.
ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    addWorker: *const fn (*anyopaque, Worker) anyerror!void,
    removeWorker: *const fn (*anyopaque, WorkerId) void,
    choose: *const fn (*anyopaque, ExcludedWorkers) ?WorkerId,
    capacityChanged: *const fn (*anyopaque, WorkerId) void,
    deinit: *const fn (*anyopaque) void,
};

// A successful registration borrows the worker until removeWorker returns.
// A failed registration must leave the selector unchanged.
pub fn addWorker(self: WorkerSelector, worker: Worker) !void {
    return self.vtable.addWorker(self.ptr, worker);
}

// Removing a worker that is not registered has no effect.
pub fn removeWorker(self: WorkerSelector, worker_id: WorkerId) void {
    self.vtable.removeWorker(self.ptr, worker_id);
}

// Choose one worker without reserving capacity. Registration enforces limits.
// Excluded workers and workers with zero capacity must not be selected.
pub fn choose(self: WorkerSelector, excluded: ExcludedWorkers) ?WorkerId {
    return self.vtable.choose(self.ptr, excluded);
}

// Publish a capacity change after updating the worker's admission state.
// Implementations refresh capacity through the registered callback.
// Notifications for workers that are no longer registered have no effect.
pub fn capacityChanged(self: WorkerSelector, worker_id: WorkerId) void {
    self.vtable.capacityChanged(self.ptr, worker_id);
}

// Release selector resources. Workers remain owned by the manager.
pub fn deinit(self: WorkerSelector) void {
    self.vtable.deinit(self.ptr);
}
