const std = @import("std");
const WorkerSelector = @import("interface.zig");
const Lock = @import("../../lock.zig");

const LinearScan = @This();

_allocator: std.mem.Allocator,
_lock: Lock,
_workers: std.ArrayList(WorkerSelector.Worker) = .empty,
_tie_cursor: usize = 0,

const vtable: WorkerSelector.VTable = .{
    .addWorker = addWorker,
    .removeWorker = removeWorker,
    .selection = selection,
    .deinit = deinit,
};

pub fn init(io: std.Io, allocator: std.mem.Allocator) LinearScan {
    return .{ ._allocator = allocator, ._lock = Lock.init(io) };
}

pub fn selector(self: *LinearScan) WorkerSelector {
    return .{ .ptr = self, .vtable = &vtable };
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
        if (worker.id != worker_id) continue;
        _ = self._workers.swapRemove(index);
        self._tie_cursor = if (self._workers.items.len == 0) 0 else self._tie_cursor % self._workers.items.len;
        return;
    }
}

// Read fresh assessments. Existing selection snapshots stay unchanged.
fn selection(ptr: *anyopaque, now_ns: std.Io.Timestamp) WorkerSelector.SelectionError!WorkerSelector.Selection {
    const self: *LinearScan = @ptrCast(@alignCast(ptr));
    var result: WorkerSelector.Selection = .{};
    {
        // Keep every borrowed worker alive until its callback has returned.
        var tx = self._lock.beginUncancelable();
        defer tx.end();

        const count = self._workers.items.len;
        if (count == 0) return result;

        const start = self._tie_cursor;
        self._tie_cursor = (start + 1) % count;

        for (self._workers.items, 0..) |worker, index| {
            switch (worker.assess_capacity(worker.ptr, now_ns)) {
                .refused => {},
                .allowed => |pressure| {
                    if (!std.math.isFinite(pressure) or pressure < 0) return error.InvalidCapacityAssessment;
                    result.candidates[result.len] = .{
                        .id = worker.id,
                        .pressure = pressure,
                        .tie_rank = (index + count - start) % count,
                    };
                    result.len += 1;
                },
            }
        }
    }

    std.mem.sort(WorkerSelector.Selection.Candidate, result.candidates[0..result.len], {}, lessThan);
    return result;
}

fn lessThan(_: void, left: WorkerSelector.Selection.Candidate, right: WorkerSelector.Selection.Candidate) bool {
    if (left.pressure == right.pressure) return left.tie_rank < right.tie_rank;
    return left.pressure < right.pressure;
}

fn deinit(ptr: *anyopaque) void {
    const self: *LinearScan = @ptrCast(@alignCast(ptr));
    var tx = self._lock.beginUncancelable();
    defer tx.end();
    self._workers.deinit(self._allocator);
    self._workers = .empty;
    self._tie_cursor = 0;
}
