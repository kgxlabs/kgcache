const std = @import("std");
const connection = @import("../connection.zig");
const TestNetwork = @import("test_network.zig");
const testing = std.testing;

test "session state exposes current snapshots through a borrowed report provider" {
    const Provider = struct {
        report: connection.ConnectionReport,
        calls: usize = 0,

        const vtable: connection.ConnectionContext.VTable = .{
            .snapshot_current = snapshotCurrent,
            .record_read = recordRead,
            .record_write = recordWrite,
        };

        fn recordRead(ptr: *anyopaque, count: u64, at: std.Io.Timestamp) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.report.recordRead(count, at);
        }

        fn recordWrite(ptr: *anyopaque, count: u64, at: std.Io.Timestamp) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.report.recordWrite(count, at);
        }

        fn snapshotCurrent(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator) connection.ConnectionContext.Error!connection.ConnectionContext.Snapshot {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            const sampled_at = std.Io.Clock.awake.now(io);
            return .{
                .id = 42,
                .peer_endpoint = .{ .ip4 = .loopback(40000) },
                .local_endpoint = .{ .ip4 = .loopback(6379) },
                .descriptor = 7,
                .registered_at = .fromNanoseconds(100),
                .sampled_at = sampled_at,
                .report = try self.report.snapshot(allocator),
            };
        }
    };

    var network = TestNetwork.init(testing.io, 0);
    network.registration_time = .fromNanoseconds(500);
    const io = network.io();
    var provider: Provider = .{ .report = connection.ConnectionReport.init(io, .fromNanoseconds(100)) };
    provider.report.recordDbAndProto(7, .resp3);
    provider.report.recordDispatch("client|info");
    const context: connection.ConnectionContext = .{
        .id = 42,
        .ptr = &provider,
        .vtable = &Provider.vtable,
    };
    const state = connection.ClientState.initWithConnection(&context);
    var request_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer request_arena.deinit();
    var snapshot = try state.connection_context.?.snapshotCurrent(io, request_arena.allocator());
    defer snapshot.deinit();

    try testing.expectEqual(context.id, snapshot.id);
    try testing.expectEqual(1, provider.calls);
    try testing.expectEqual(1, network.awake_samples.load(.acquire));
    try testing.expectEqual(std.Io.Timestamp.fromNanoseconds(500), snapshot.sampled_at);
    try testing.expectEqual(7, snapshot.report.values.db_index);
    try testing.expectEqual(@import("../protocol.zig").Resp.Version.resp3, snapshot.report.values.resp);
    try testing.expectEqualStrings("client|info", snapshot.report.values.last_command);
    try testing.expectEqual(0, state.db_index);
    try testing.expectEqual(@import("../protocol.zig").Resp.Version.resp2, state.resp.version());
    var tx = provider.report._lock.tryBegin() orelse return error.ReportLockStillHeld;
    tx.end();

    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, state.connection_context.?.snapshotCurrent(io, failing.allocator()));
    try testing.expectEqual(2, provider.calls);
    try testing.expectEqual(2, network.awake_samples.load(.acquire));
    tx = provider.report._lock.tryBegin() orelse return error.ReportLockStillHeld;
    tx.end();
}
