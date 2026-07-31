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

fn execute(ptr: *anyopaque, _: std.Io, data_store: *store.Store) Commander.Error!resp.RESPValue {
    const self: *DBSize = @ptrCast(@alignCast(ptr));
    if (self.arguments.len != 0) {
        return .{ .simple_error = "Wrong number of arguments" };
    }

    return .{ .integer = @intCast(data_store.dbsize()) };
}

fn deinit(ptr: *anyopaque) void {
    const self: *DBSize = @ptrCast(@alignCast(ptr));
    self.allocator.destroy(self);
}

test "execute returns the store size" {
    const testing = std.testing;

    var values = [_]resp.RESPValue{.{ .bulk_string = "DBSIZE" }};
    const command = try TestHelpers.initCommand(testing.allocator, .{ .array = &values });

    const result = try TestHelpers.executeWithMemoryStore(command);
    try testing.expectEqual(@as(i64, 0), result.integer);
}

test "execute delegates to the store dbsize operation" {
    const testing = std.testing;

    var values = [_]resp.RESPValue{.{ .bulk_string = "DBSIZE" }};
    const command = try TestHelpers.initCommand(testing.allocator, .{ .array = &values });
    defer command.deinit();

    var mock_store = MockStore.init();
    mock_store.dbsize_result = 42;
    var data_store = mock_store.store();

    const result = try command.execute(testing.io, &data_store);
    try testing.expectEqual(@as(i64, 42), result.integer);
    try testing.expectEqual(1, mock_store.dbsize_calls);
}

test "rejects arguments" {
    const testing = std.testing;

    var values = [_]resp.RESPValue{
        .{ .bulk_string = "DBSIZE" },
        .{ .bulk_string = "unexpected" },
    };
    const command = try TestHelpers.initCommand(testing.allocator, .{ .array = &values });

    const result = try TestHelpers.executeWithMemoryStore(command);
    switch (result) {
        .simple_error => |message| try testing.expectEqualStrings("Wrong number of arguments", message),
        else => return error.TestUnexpectedResult,
    }
}
