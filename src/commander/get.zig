const std = @import("std");
const resp = @import("../resp.zig");
const store = @import("../store.zig");
const command_arguments = @import("arguments.zig");
const Commander = @import("interface.zig");

const Get = @This();

allocator: std.mem.Allocator,
arguments: []resp.RESPValue,

pub fn commander(self: *Get) Commander {
    return .{ .ptr = self, .vtable = &vtable };
}

const vtable = Commander.VTable{
    .execute = execute,
    .deinit = deinit,
};

fn execute(ptr: *anyopaque, _: std.Io, data_store: *store.Store, client_state: *Commander.ClientState) anyerror!Commander.Result {
    const self: *Get = @ptrCast(@alignCast(ptr));

    const key = try command_arguments.bulkString(self.arguments[0]);
    const maybe_object = try data_store.get(key, client_state.db_index);

    if (maybe_object == null) {
        return Commander.Result.borrowed(.{ .bulk_string = null });
    }

    return try Commander.Result.owned(maybe_object.?);
}

fn deinit(ptr: *anyopaque) void {
    const self: *Get = @ptrCast(@alignCast(ptr));
    self.allocator.destroy(self);
}
