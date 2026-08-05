const std = @import("std");
const resp = @import("../resp.zig");
const store = @import("../store.zig");
const Commander = @import("interface.zig");
const TestHelpers = @import("../tests/helpers.zig");

const Save = @This();

allocator: std.mem.Allocator,
arguments: []resp.RESPValue,

pub fn commander(self: *Save) Commander {
    return .{ .ptr = self, .vtable = &vtable };
}

const vtable = Commander.VTable{ .execute = execute, .deinit = deinit };

fn execute(ptr: *anyopaque, _: std.Io, _: *store.Store) Commander.Error!resp.RESPValue {
    const self: *Save = @ptrCast(@alignCast(ptr));

    if (self.arguments.len > 0) {
        return .{ .simple_error = "Wrong number of arguments" };
    }

    return resp.RESPValue{
        .bulk_string = "OK",
    };
}

fn deinit(ptr: *anyopaque) void {
    const self: *Save = @ptrCast(@alignCast(ptr));
    self.allocator.destroy(self);
}
