const std = @import("std");
const store = @import("../store.zig");
const Commander = @import("interface.zig");
const TestHelpers = @import("../tests/helpers.zig");

const Echo = @This();

allocator: std.mem.Allocator,
arguments: []const []const u8,

pub fn commander(self: *Echo) Commander {
    return .{ .ptr = self, .vtable = &vtable };
}

const vtable = Commander.VTable{
    .execute = execute,
    .deinit = deinit,
};

fn execute(ptr: *anyopaque, _: std.Io, _: *store.Store, _: *Commander.ClientState) Commander.Error!Commander.Result {
    const self: *Echo = @ptrCast(@alignCast(ptr));

    return Commander.Result.borrowed(.{ .blob_string = self.arguments[0] });
}

fn deinit(ptr: *anyopaque) void {
    const self: *Echo = @ptrCast(@alignCast(ptr));
    self.allocator.destroy(self);
}

test "execute echo command" {
    const testing = std.testing;
    const values = [_][]const u8{
        "ECHO",
        "hello",
    };

    var result = try TestHelpers.executeWithMemoryStore(try TestHelpers.initCommand(testing.allocator, .{ .name = values[0], .arguments = values[1..] }));
    defer result.deinit();
    switch (result.value) {
        .blob_string => |actual| try testing.expectEqualStrings("hello", actual),
        else => return error.TestUnexpectedResult,
    }
}

test "decoder rejects non-bulk ECHO arguments before execution" {
    const decoder = @import("../protocol/request_decoder.zig");
    try std.testing.expectError(error.ExpectedBulkString, decoder.decode("*2\r\n$4\r\nECHO\r\n:1\r\n", std.testing.allocator, decoder.aof_limits));
}
