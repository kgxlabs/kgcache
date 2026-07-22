const std = @import("std");
const resp = @import("../resp.zig");
const store = @import("../store.zig");
const Commander = @import("interface.zig");

const Command = @This();

allocator: std.mem.Allocator,
arguments: []resp.RESPValue,

pub fn commander(self: *Command) Commander {
    return .{ .ptr = self, .vtable = &vtable };
}

const vtable = Commander.VTable{ .execute = execute, .deinit = deinit };

fn execute(ptr: *anyopaque, _: *store.Store) Commander.Error!resp.RESPValue {
    const self: *Command = @ptrCast(@alignCast(ptr));

    if (self.arguments.len == 0) {
        return .{ .simple_error = "Wrong number of arguments" };
    }

    // TODO: Implement introspection.
    return self.arguments[0];
}

fn deinit(ptr: *anyopaque) void {
    const self: *Command = @ptrCast(@alignCast(ptr));
    self.allocator.destroy(self);
}
