const std = @import("std");
const store = @import("../store.zig");
const Commander = @import("interface.zig");

const Get = @This();

allocator: std.mem.Allocator,
arguments: []const []const u8,

pub fn commander(self: *Get) Commander {
    return .{ .ptr = self, .vtable = &vtable };
}

const vtable = Commander.VTable{
    .execute = execute,
    .deinit = deinit,
};

fn execute(ptr: *anyopaque, _: std.Io, data_store: *store.Store, client_state: *Commander.ClientState) anyerror!Commander.Result {
    const self: *Get = @ptrCast(@alignCast(ptr));

    const key = self.arguments[0];
    const maybe_object = try data_store.get(key, client_state.db_index);

    if (maybe_object == null) {
        return Commander.Result.borrowed(.{ .null_value = .bulk_string });
    }

    return try Commander.Result.owned(maybe_object.?);
}

fn deinit(ptr: *anyopaque) void {
    const self: *Get = @ptrCast(@alignCast(ptr));
    self.allocator.destroy(self);
}
