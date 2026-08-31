const std = @import("std");
const resp = @import("../resp.zig");
const store = @import("../store.zig");
const command_arguments = @import("arguments.zig");
const Commander = @import("interface.zig");

const Del = @This();

allocator: std.mem.Allocator,
arguments: []resp.RESPValue,

pub fn commander(self: *Del) Commander {
    return .{ .ptr = self, .vtable = &vtable };
}

const vtable: Commander.VTable = .{
    .execute = execute,
    .deinit = deinit,
};

fn execute(
    ptr: *anyopaque,
    _: std.Io,
    data_store: *store.Store,
    client_state: *Commander.ClientState,
) Commander.Error!resp.RESPValue {
    const self: *Del = @ptrCast(@alignCast(ptr));

    if (self.arguments.len == 0) return error.WrongNumberArguments;

    var removed: i64 = 0;
    for (self.arguments) |argument| {
        const key = try command_arguments.bulkString(argument);
        if (data_store.remove(key, client_state.db_index) catch |err| {
            return .{ .simple_error = store.errorToString(err) };
        }) removed += 1;
    }

    return .{ .integer = removed };
}

fn deinit(ptr: *anyopaque) void {
    const self: *Del = @ptrCast(@alignCast(ptr));
    self.allocator.destroy(self);
}
