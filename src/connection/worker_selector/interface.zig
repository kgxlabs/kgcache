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

// Owns one selection state. Copies share the same state.
// Call deinit exactly once, even when iteration stops early.
pub const Selection = struct {
    ptr: *anyopaque,
    vtable: *const SelectionVTable,

    pub const SelectionVTable = struct {
        next: *const fn (*anyopaque) ?WorkerId,
        deinit: *const fn (*anyopaque) void,
    };

    pub fn next(self: *Selection) ?WorkerId {
        return self.vtable.next(self.ptr);
    }

    pub fn deinit(self: *Selection) void {
        self.vtable.deinit(self.ptr);
    }
};

// This handle borrows its implementation. Workers must stop using it before
// the implementation is destroyed. Implementations synchronize shared state.
ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    addWorker: *const fn (*anyopaque, Worker) anyerror!void,
    removeWorker: *const fn (*anyopaque, WorkerId) void,
    selection: *const fn (*anyopaque) anyerror!Selection,
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

// Get a "selection handle" which you can use to iterate through the worker lists in order of highest "capacity" to lowest "capacity"
pub fn selection(self: WorkerSelector) !Selection {
    return self.vtable.selection(self.ptr);
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
