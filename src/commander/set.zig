const std = @import("std");
const resp = @import("../resp.zig");
const store = @import("../store.zig");
const object = @import("../object.zig");
const command_arguments = @import("arguments.zig");
const Commander = @import("interface.zig");
const Request = @import("request.zig");

const Set = @This();

allocator: std.mem.Allocator,
arguments: []resp.RESPValue,

pub fn commander(self: *Set) Commander {
    return .{ .ptr = self, .vtable = &vtable };
}

const vtable = Commander.VTable{
    .execute = execute,
    .deinit = deinit,
};

fn execute(ptr: *anyopaque, data_store: *store.Store) Commander.Error!resp.RESPValue {
    const self: *Set = @ptrCast(@alignCast(ptr));

    if (self.arguments.len < 2) {
        return Commander.Error.WrongNumberArguments;
    }

    const req = try bind(self.arguments);
    const maybe_object = data_store.set(req) catch |err| {
        return .{ .simple_error = store.errorToString(err) };
    };

    if (maybe_object == null) {
        return .{ .simple_string = "OK" };
    }

    return object.toRESP(maybe_object.?) catch Commander.Error.UnableToConvertObject;
}

const schema = .{
    .required = 2,
};

fn bind(argv: []resp.RESPValue) Commander.Error!Request.SetRequest {
    const key = try command_arguments.bulkString(argv[0]);
    const value = try command_arguments.bulkString(argv[1]);

    return .{
        .key = key,
        .value = value,
    };
}

fn deinit(ptr: *anyopaque) void {
    const self: *Set = @ptrCast(@alignCast(ptr));
    self.allocator.destroy(self);
}
