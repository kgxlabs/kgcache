const std = @import("std");
const resp = @import("../resp.zig");
const store = @import("../store.zig");
const object = @import("../object.zig");
const command_arguments = @import("arguments.zig");
const Commander = @import("interface.zig");

const Get = @This();

allocator: std.mem.Allocator,
arguments: []resp.RESPValue,

pub fn commander(self: *Get) Commander {
    return .{ .ptr = self, .vtable = &vtable };
}

const vtable = Commander.VTable{ .execute = execute, .deinit = deinit };

fn execute(ptr: *anyopaque, data_store: *store.Store) Commander.Error!resp.RESPValue {
    const self: *Get = @ptrCast(@alignCast(ptr));

    if (self.arguments.len == 0) {
        return .{ .simple_error = "Wrong number of arguments" };
    }

    const key = try command_arguments.bulkString(self.arguments[0]);
    const maybe_object = data_store.get(key) catch return .{ .simple_error = "Unable to get" };

    if (maybe_object == null) {
        return .{ .bulk_string = null };
    }

    return object.toRESP(maybe_object.?) catch Commander.Error.UnableToConvertObject;
}

fn deinit(ptr: *anyopaque) void {
    const self: *Get = @ptrCast(@alignCast(ptr));
    self.allocator.destroy(self);
}
