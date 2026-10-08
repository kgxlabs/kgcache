const std = @import("std");
const store = @import("../store.zig");
const Commander = @import("interface.zig");

const Del = @This();

allocator: std.mem.Allocator,
arguments: []const []const u8,

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
) anyerror!Commander.Result {
    const self: *Del = @ptrCast(@alignCast(ptr));

    var removed: i64 = 0;
    for (self.arguments) |argument| {
        const key = argument;
        const result = try data_store.remove(key, client_state.db_index);
        if (result.outcome == .applied) removed += 1;
    }

    return Commander.Result.borrowed(.{ .integer = removed });
}

fn deinit(ptr: *anyopaque) void {
    const self: *Del = @ptrCast(@alignCast(ptr));
    self.allocator.destroy(self);
}
