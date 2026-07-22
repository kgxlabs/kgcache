const std = @import("std");
const resp = @import("../resp.zig");
const store = @import("../store.zig");
const Commander = @import("interface.zig");
const TestHelpers = @import("../tests/helpers.zig");

const Echo = @This();

allocator: std.mem.Allocator,
arguments: []resp.RESPValue,

pub fn commander(self: *Echo) Commander {
    return .{ .ptr = self, .vtable = &vtable };
}

const vtable = Commander.VTable{ .execute = execute, .deinit = deinit };

fn execute(ptr: *anyopaque, _: *store.Store) Commander.Error!resp.RESPValue {
    const self: *Echo = @ptrCast(@alignCast(ptr));

    if (self.arguments.len != 1) {
        return .{ .simple_error = "Wrong number of arguments" };
    }

    return switch (self.arguments[0]) {
        .bulk_string => |maybe_string| .{ .bulk_string = maybe_string orelse return Commander.Error.MalformedCommandRequest },
        else => Commander.Error.UnsupportedArgumentType,
    };
}

fn deinit(ptr: *anyopaque) void {
    const self: *Echo = @ptrCast(@alignCast(ptr));
    self.allocator.destroy(self);
}

test "execute echo command" {
    const testing = std.testing;
    var values = [_]resp.RESPValue{
        .{ .bulk_string = "ECHO" },
        .{ .bulk_string = "hello" },
    };

    const result = try TestHelpers.executeWithMemoryStore(try commander.init(testing.allocator, .{ .array = &values }));
    switch (result) {
        .bulk_string => |maybe_actual| try testing.expectEqualStrings("hello", maybe_actual orelse return error.TestUnexpectedResult),
        else => return error.TestUnexpectedResult,
    }
}

test "reject unsupported argument type" {
    const testing = std.testing;
    var values = [_]resp.RESPValue{
        .{ .bulk_string = "ECHO" },
        .{ .integer = 1 },
    };

    try testing.expectError(
        error.UnsupportedArgumentType,
        TestHelpers.executeWithMemoryStore(try commander.init(testing.allocator, .{ .array = &values })),
    );
}
