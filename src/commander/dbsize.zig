const std = @import("std");
const resp = @import("../resp.zig");
const store = @import("../store.zig");
const Commander = @import("interface.zig");
const TestHelpers = @import("../tests/helpers.zig");
const MockStore = @import("../store/mock_store.zig");

const DBSize = @This();

allocator: std.mem.Allocator,
arguments: []resp.RESPValue,

pub fn commander(self: *DBSize) Commander {
    return .{ .ptr = self, .vtable = &vtable };
}

const vtable = Commander.VTable{ .execute = execute, .deinit = deinit };

fn execute(_: *anyopaque, _: std.Io, data_store: *store.Store, client_state: *Commander.ClientState) anyerror!Commander.Result {
    const size = try data_store.dbsize(client_state.db_index);
    return Commander.Result.borrowed(.{ .integer = @intCast(size) });
}

fn deinit(ptr: *anyopaque) void {
    const self: *DBSize = @ptrCast(@alignCast(ptr));
    self.allocator.destroy(self);
}

test "execute returns the store size" {
    const testing = std.testing;

    var values = [_]resp.RESPValue{.{ .bulk_string = "DBSIZE" }};
    const command = try TestHelpers.initCommand(testing.allocator, .{ .array = &values });

    var result = try TestHelpers.executeWithMemoryStore(command);
    defer result.deinit();
    try testing.expectEqual(@as(i64, 0), result.value.integer);
}

test "execute delegates to the store dbsize operation" {
    const testing = std.testing;

    var values = [_]resp.RESPValue{.{ .bulk_string = "DBSIZE" }};
    const command = try TestHelpers.initCommand(testing.allocator, .{ .array = &values });
    defer command.deinit();

    var mock_store = MockStore.init();
    mock_store.dbsize_result = 42;
    var data_store = mock_store.store();
    var client_state: Commander.ClientState = .{};

    var result = try command.execute(testing.io, &data_store, &client_state);
    defer result.deinit();
    try testing.expectEqual(@as(i64, 42), result.value.integer);
    try testing.expectEqual(1, mock_store.dbsize_calls);
}
