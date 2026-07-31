const std = @import("std");
const resp = @import("../resp.zig");
const store = @import("../store.zig");
const Commander = @import("interface.zig");
const TestHelpers = @import("../tests/helpers.zig");

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
