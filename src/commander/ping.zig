const std = @import("std");
const resp = @import("../resp.zig");
const store = @import("../store.zig");
const Commander = @import("interface.zig");

const Ping = @This();

allocator: std.mem.Allocator,
arguments: []resp.RESPValue,

pub fn commander(self: *Ping) Commander {
    return .{ .ptr = self, .vtable = &vtable };
}

const vtable = Commander.VTable{ .execute = execute, .deinit = deinit };

fn execute(_: *anyopaque, _: *store.Store) Commander.Error!resp.RESPValue {
    return .{ .simple_string = "PONG" };
}

fn deinit(ptr: *anyopaque) void {
    const self: *Ping = @ptrCast(@alignCast(ptr));
    self.allocator.destroy(self);
}

test "execute ping command" {
    const testing = std.testing;
    var values = [_]resp.RESPValue{.{ .bulk_string = "PING" }};
    const command = try commander.init(testing.allocator, .{ .array = &values });
    defer command.deinit();

    var memory_store = store.MemoryStore.init(testing.allocator);
    var data_store = memory_store.store();
    defer data_store.deinit();

    const result = try command.execute(&data_store);
    switch (result) {
        .simple_string => |actual| try testing.expectEqualStrings("PONG", actual),
        else => return error.TestUnexpectedResult,
    }
}
