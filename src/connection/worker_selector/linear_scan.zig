const std = @import("std");
const WorkerSelector = @import("interface.zig");
const Lock = @import("../../lock.zig");

const LinearScan = @This();

_allocator: std.mem.Allocator,
_lock: Lock,
_workers: std.ArrayList(WorkerSelector.Worker) = .empty,

const vtable: WorkerSelector.VTable = .{
    .addWorker = addWorker,
    .removeWorker = removeWorker,
    .selection = selection,
    .capacityChanged = capacityChanged,
    .deinit = deinit,
};

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

fn selection(ptr: *anyopaque) !WorkerSelector.Selection {
    const self: *LinearScan = @ptrCast(@alignCast(ptr));
    const state = try self._allocator.create(Selection);
    errdefer self._allocator.destroy(state);

    {
        var lock_tx = try self._lock.begin();
        defer lock_tx.end();

        const workers = try self._allocator.alloc(Selection.Candidate, self._workers.items.len);
        for (self._workers.items, workers) |worker, *snapshot| {
            snapshot.* = .{
                .id = worker.id,
                .capacity = worker.available_capacity(worker.ptr),
            };
        }

        state.* = Selection.init(self._allocator, workers);
    }

    return state.selection();
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

pub const Selection = struct {
    _allocator: std.mem.Allocator,
    _workers: []Candidate,

    pub const Candidate = struct {
        id: WorkerSelector.WorkerId,
        capacity: usize,
    };

    const selection_vtable: WorkerSelector.Selection.SelectionVTable = .{
        .next = Selection.next,
        .deinit = Selection.deinit,
    };

    // Takes ownership of the snapshot captured under the selector's lock.
    // Later capacity changes do not update this snapshot.
    pub fn init(allocator: std.mem.Allocator, workers: []Candidate) Selection {
        return .{
            ._allocator = allocator,
            ._workers = workers,
        };
    }

    pub fn selection(self: *Selection) WorkerSelector.Selection {
        return .{
            .ptr = self,
            .vtable = &selection_vtable,
        };
    }

    fn next(_: *anyopaque) ?WorkerSelector.WorkerId {
        @panic("LinearScan.Selection.next is not implemented");
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *Selection = @ptrCast(@alignCast(ptr));
        const allocator = self._allocator;

        allocator.free(self._workers);
        allocator.destroy(self);
    }
};
