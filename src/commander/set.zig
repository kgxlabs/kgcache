const std = @import("std");
const resp = @import("../resp.zig");
const store = @import("../store.zig");
const object = @import("../object.zig");
const command_arguments = @import("arguments.zig");
const Commander = @import("interface.zig");

const Set = @This();

allocator: std.mem.Allocator,
arguments: []resp.RESPValue,

pub fn commander(self: *Set) Commander {
    return .{ .ptr = self, .vtable = &vtable };
}

const vtable = Commander.VTable{ .execute = execute, .deinit = deinit };

fn execute(ptr: *anyopaque, data_store: *store.Store) Commander.Error!resp.RESPValue {
    const self: *Set = @ptrCast(@alignCast(ptr));

    if (self.arguments.len < 2) {
        return Commander.Error.WrongNumberArguments;
    }

    const key = try command_arguments.bulkString(self.arguments[0]);
    const value = try command_arguments.bulkString(self.arguments[1]);
    const maybe_object = data_store.set(key, value) catch |err| {
        return .{ .simple_error = store.errorToString(err) };
    };

    if (maybe_object == null) {
        return .{ .simple_string = "OK" };
    }

    return object.toRESP(maybe_object.?) catch Commander.Error.UnableToConvertObject;
}

fn deinit(ptr: *anyopaque) void {
    const self: *Set = @ptrCast(@alignCast(ptr));
    self.allocator.destroy(self);
}
