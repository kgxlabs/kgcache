const std = @import("std");
const WorkerSelector = @import("interface.zig");
const Lock = @import("../../lock.zig");

const LinearScan = @This();

_allocator: std.mem.Allocator,
_lock: Lock,
_workers: std.ArrayList(WorkerSelector.Worker) = .empty,

pub fn init(io: std.Io, allocator: std.mem.Allocator) LinearScan {
    return .{
        ._allocator = allocator,
        ._lock = Lock.init(io),
    };
}

// Borrow this handle only after the implementation has reached a stable address.
pub fn selector(self: *LinearScan) WorkerSelector {
    return .{
        .ptr = self,
        .vtable = &vtable,
    };
}

const vtable: WorkerSelector.VTable = .{
    .addWorker = addWorker,
    .removeWorker = removeWorker,
    .choose = choose,
    .capacityChanged = capacityChanged,
    .deinit = deinit,
};

fn addWorker(ptr: *anyopaque, worker: WorkerSelector.Worker) anyerror!void {
    const self: *LinearScan = @ptrCast(@alignCast(ptr));
    if (worker.id >= WorkerSelector.max_workers) return error.InvalidWorkerId;

    var tx = self._lock.beginUncancelable();
    defer tx.end();

    for (self._workers.items) |registered| {
        if (registered.id == worker.id) return error.WorkerAlreadyRegistered;
    }

    try self._workers.append(self._allocator, worker);
}

fn removeWorker(ptr: *anyopaque, worker_id: WorkerSelector.WorkerId) void {
    const self: *LinearScan = @ptrCast(@alignCast(ptr));
    var tx = self._lock.beginUncancelable();
    defer tx.end();

    for (self._workers.items, 0..) |worker, index| {
        if (worker.id == worker_id) {
            _ = self._workers.swapRemove(index);
            return;
        }
    }
}

fn choose(ptr: *anyopaque, excluded: WorkerSelector.ExcludedWorkers) ?WorkerSelector.WorkerId {
    const self: *LinearScan = @ptrCast(@alignCast(ptr));
    // Keep registration alive until every capacity callback has returned.
    var tx = self._lock.beginUncancelable();
    defer tx.end();

    var best_worker: ?WorkerSelector.WorkerId = null;
    var best_capacity: usize = 0;

    for (self._workers.items) |worker| {
        if (excluded.isSet(worker.id)) continue;

        const capacity = worker.available_capacity(worker.ptr);
        if (capacity > best_capacity) {
            best_worker = worker.id;
            best_capacity = capacity;
        }
    }

    return best_worker;
}

// Each scan reads current capacity, so there is no cached order to update.
fn capacityChanged(_: *anyopaque, _: WorkerSelector.WorkerId) void {}

fn deinit(ptr: *anyopaque) void {
    const self: *LinearScan = @ptrCast(@alignCast(ptr));
    var tx = self._lock.beginUncancelable();
    defer tx.end();

    self._workers.deinit(self._allocator);
    self._workers = .empty;
}
