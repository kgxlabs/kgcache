const std = @import("std");
const connection = @import("../connection.zig");
const TestNetwork = @import("test_network.zig");
const protocol = @import("../protocol.zig");
const testing = std.testing;

test "session state exposes current snapshots through a borrowed report provider" {
    const Provider = struct {
        report: connection.ConnectionReport,
        calls: usize = 0,

        const vtable: connection.ConnectionContext.VTable = .{
            .snapshot_current = snapshotCurrent,
            .snapshot_live = snapshotLive,
            .record_read = recordRead,
            .record_write = recordWrite,
            .record_dispatch = recordDispatch,
            .record_db_and_proto = recordDbAndProto,
            .set_library_info = setLibraryInfo,
        };

        fn recordRead(ptr: *anyopaque, count: u64, at: std.Io.Timestamp) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.report.recordRead(count, at);
        }

        fn recordWrite(ptr: *anyopaque, count: u64, at: std.Io.Timestamp) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.report.recordWrite(count, at);
        }

        fn recordDispatch(ptr: *anyopaque, name: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.report.recordDispatch(name);
        }

        fn recordDbAndProto(ptr: *anyopaque, db_index: u32, resp: protocol.Resp.Version) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.report.recordDbAndProto(db_index, resp);
        }

        fn setLibraryInfo(ptr: *anyopaque, attribute: connection.ConnectionReport.LibraryAttribute, value: []const u8) connection.ConnectionContext.Error!void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return self.report.setLibraryInfo(attribute, value);
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

        fn snapshotLive(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator) connection.ConnectionContext.Error!connection.ConnectionContext.LiveSnapshots {
            const items = try allocator.alloc(connection.ConnectionContext.Snapshot, 1);
            errdefer allocator.free(items);
            items[0] = try snapshotCurrent(ptr, io, allocator);
            return .{ .items = items, .allocator = allocator };
        }
    };

    var network = TestNetwork.init(testing.io, 0);
    network.registration_time = .fromNanoseconds(500);
    const io = network.io();
    var provider: Provider = .{ .report = connection.ConnectionReport.init(io, testing.allocator, .fromNanoseconds(100)) };
    const context: connection.ConnectionContext = .{
        .id = 42,
        .ptr = &provider,
        .vtable = &Provider.vtable,
    };
    context.recordDbAndProto(7, .resp3);
    context.recordDispatch("client|info");
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

test "live snapshot access is supplied by the borrowed context provider" {
    const Context = connection.ConnectionContext;
    const Provider = struct {
        calls: usize = 0,

        fn live(ptr: *anyopaque, _: std.Io, allocator: std.mem.Allocator) Context.Error!Context.LiveSnapshots {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            return .{ .items = try allocator.alloc(Context.Snapshot, 0), .allocator = allocator };
        }
    };
    var provider: Provider = .{};
    var vtable = TestNetwork.identityContext(1).vtable.*;
    vtable.snapshot_live = Provider.live;
    const context: Context = .{ .id = 1, .ptr = &provider, .vtable = &vtable };
    var snapshots = try context.snapshotLive(testing.io, testing.allocator);
    defer snapshots.deinit();
    try testing.expectEqual(1, provider.calls);
    try testing.expectEqual(0, snapshots.items.len);
}
