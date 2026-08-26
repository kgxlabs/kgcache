const std = @import("std");
const resp = @import("../resp.zig");
const store = @import("../store.zig");
const Commander = @import("interface.zig");
const TestHelpers = @import("../tests/helpers.zig");

const BgRewriteAof = @This();

allocator: std.mem.Allocator,
arguments: []resp.RESPValue,

pub fn commander(self: *BgRewriteAof) Commander {
    return .{ .ptr = self, .vtable = &vtable };
}

const vtable = Commander.VTable{
    .execute = execute,
    .deinit = deinit,
};

fn execute(_: *anyopaque, _: std.Io, _: *store.Store, _: *Commander.ClientState) Commander.Error!resp.RESPValue {
    return .{ .simple_string = "OK" };
}

fn deinit(ptr: *anyopaque) void {
    const self: *BgRewriteAof = @ptrCast(@alignCast(ptr));
    self.allocator.destroy(self);
}

test "execute echo command" {
    const testing = std.testing;
    var values = [_]resp.RESPValue{
        .{ .bulk_string = "ECHO" },
        .{ .bulk_string = "hello" },
    };

    const result = try TestHelpers.executeWithMemoryStore(try TestHelpers.initCommand(testing.allocator, .{ .array = &values }));
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
        TestHelpers.executeWithMemoryStore(try TestHelpers.initCommand(testing.allocator, .{ .array = &values })),
    );
}
