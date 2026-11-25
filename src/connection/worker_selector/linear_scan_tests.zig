const std = @import("std");
const LinearScan = @import("linear_scan.zig");
const WorkerSelector = @import("interface.zig");
const CapacityCalculator = @import("../capacity.zig");

const FakeWorker = struct {
    assessment: CapacityCalculator.Assessment,
    calls: usize = 0,
    last_now_ns: ?std.Io.Timestamp = null,

    fn source(self: *FakeWorker, id: WorkerSelector.WorkerId) WorkerSelector.Worker {
        return .{ .id = id, .ptr = self, .assess_capacity = assess };
    }

    fn assess(ptr: *anyopaque, now_ns: std.Io.Timestamp) CapacityCalculator.Assessment {
        const self: *FakeWorker = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        self.last_now_ns = now_ns;
        return self.assessment;
    }
};

test "capacity selector filters refusals and accepts zero pressure" {
    const testing = std.testing;
    var implementation = LinearScan.init(testing.io, testing.allocator);
    const selector = implementation.selector();
    defer selector.deinit();

    var empty = try selector.selection(std.Io.Timestamp.fromNanoseconds(1));
    try testing.expectEqual(null, empty.next());
    var workers = [_]FakeWorker{
        .{ .assessment = .{ .allowed = 4 } },
        .{ .assessment = .{ .refused = error.ReadyDelayLimit } },
        .{ .assessment = .{ .allowed = 0 } },
        .{ .assessment = .{ .allowed = 0.5 } },
    };
    for (&workers, 1..) |*worker, id| try selector.addWorker(worker.source(@intCast(id)));

    var selection = try selector.selection(std.Io.Timestamp.fromNanoseconds(123));
    try testing.expectEqual(@as(?WorkerSelector.WorkerId, 3), selection.next());
    try testing.expectEqual(@as(?WorkerSelector.WorkerId, 4), selection.next());
    try testing.expectEqual(@as(?WorkerSelector.WorkerId, 1), selection.next());
    try testing.expectEqual(null, selection.next());
    try testing.expectEqual(null, selection.next());
    for (workers) |worker| {
        try testing.expectEqual(1, worker.calls);
        try testing.expectEqual(@as(?std.Io.Timestamp, std.Io.Timestamp.fromNanoseconds(123)), worker.last_now_ns);
    }
}

test "capacity selector rotates equal pressure candidates" {
    const testing = std.testing;
    var implementation = LinearScan.init(testing.io, testing.allocator);
    const selector = implementation.selector();
    defer selector.deinit();
    var workers = [_]FakeWorker{
        .{ .assessment = .{ .allowed = 1 } },
        .{ .assessment = .{ .allowed = 1 } },
        .{ .assessment = .{ .allowed = 1 } },
    };
    for (&workers, 5..) |*worker, id| try selector.addWorker(worker.source(@intCast(id)));
    for (0..3) |start| {
        var selection = try selector.selection(std.Io.Timestamp.fromNanoseconds(10));
        for (0..3) |offset| {
            const expected: WorkerSelector.WorkerId = @intCast(5 + (start + offset) % 3);
            try testing.expectEqual(@as(?WorkerSelector.WorkerId, expected), selection.next());
        }
        try testing.expectEqual(null, selection.next());
    }
}

test "capacity selector snapshots survive assessment changes and worker removal" {
    const testing = std.testing;
    var implementation = LinearScan.init(testing.io, testing.allocator);
    const selector = implementation.selector();
    defer selector.deinit();
    var first: FakeWorker = .{ .assessment = .{ .allowed = 0 } };
    var second: FakeWorker = .{ .assessment = .{ .allowed = 2 } };
    try selector.addWorker(first.source(1));
    try selector.addWorker(second.source(2));
    var old = try selector.selection(std.Io.Timestamp.fromNanoseconds(6));

    first.assessment = .{ .refused = error.WorkerNotAccepting };
    second.assessment = .{ .allowed = 0 };
    var fresh = try selector.selection(std.Io.Timestamp.fromNanoseconds(7));
    try testing.expectEqual(@as(?WorkerSelector.WorkerId, 2), fresh.next());
    try testing.expectEqual(null, fresh.next());

    selector.removeWorker(1);
    selector.removeWorker(1);
    var remaining = try selector.selection(std.Io.Timestamp.fromNanoseconds(8));
    try testing.expectEqual(@as(?WorkerSelector.WorkerId, 2), remaining.next());
    try testing.expectEqual(null, remaining.next());
    try testing.expectEqual(@as(?WorkerSelector.WorkerId, 1), old.next());
    try testing.expectEqual(@as(?WorkerSelector.WorkerId, 2), old.next());
    try testing.expectEqual(null, old.next());
    try testing.expectEqual(2, first.calls);
    try testing.expectEqual(3, second.calls);
}

test "capacity selector rejects invalid and duplicate worker IDs without replacement" {
    const testing = std.testing;
    var implementation = LinearScan.init(testing.io, testing.allocator);
    const selector = implementation.selector();
    defer selector.deinit();
    var registered: FakeWorker = .{ .assessment = .{ .allowed = 0 } };
    var other: FakeWorker = .{ .assessment = .{ .refused = error.WorkerNotAccepting } };
    try selector.addWorker(registered.source(1));
    try testing.expectError(error.WorkerAlreadyRegistered, selector.addWorker(other.source(1)));
    try testing.expectError(error.InvalidWorkerId, selector.addWorker(other.source(WorkerSelector.max_workers)));
    var selection = try selector.selection(std.Io.Timestamp.fromNanoseconds(8));
    try testing.expectEqual(@as(?WorkerSelector.WorkerId, 1), selection.next());
    try testing.expectEqual(null, selection.next());
    try testing.expectEqual(1, registered.calls);
    try testing.expectEqual(0, other.calls);
}

test "capacity selector rejects negative and nonfinite pressure" {
    const testing = std.testing;
    var implementation = LinearScan.init(testing.io, testing.allocator);
    const selector = implementation.selector();
    defer selector.deinit();
    var worker: FakeWorker = .{ .assessment = .{ .allowed = 0 } };
    try selector.addWorker(worker.source(1));

    const invalid_pressures = [_]f64{ -1, std.math.nan(f64), std.math.inf(f64), -std.math.inf(f64) };
    for (invalid_pressures) |pressure| {
        worker.assessment = .{ .allowed = pressure };
        try testing.expectError(error.InvalidCapacityAssessment, selector.selection(.zero));
    }

    worker.assessment = .{ .allowed = 0 };
    var selection = try selector.selection(.zero);
    try testing.expectEqual(@as(?WorkerSelector.WorkerId, 1), selection.next());
    try testing.expectEqual(null, selection.next());
}
