const std = @import("std");
const resp = @import("../resp.zig");
const store = @import("../store.zig");
const Commander = @import("interface.zig");
const command_arguments = @import("arguments.zig");

const BgSave = @This();

allocator: std.mem.Allocator,
arguments: []resp.RESPValue,

pub fn commander(self: *BgSave) Commander {
    return .{ .ptr = self, .vtable = &vtable };
}

const vtable = Commander.VTable{ .execute = execute, .deinit = deinit };

// NOTE: Regardless of having `SCHEDULE` option is there or not, the `bgsave` commander behaves the same.
// `SCHEDULE` option is soley for Redis compatibility.
fn execute(ptr: *anyopaque, _: std.Io, data_store: *store.Store, _: *Commander.ClientState) anyerror!Commander.Result {
    const self: *BgSave = @ptrCast(@alignCast(ptr));

    if (self.arguments.len > 1) return error.WrongNumberArguments;

    if (self.arguments.len == 1) {
        const option = try command_arguments.bulkString(self.arguments[0]);
        if (!std.ascii.eqlIgnoreCase(option, "schedule")) return Commander.Error.Syntax;
    }

    const outcome = try data_store.bgsave(.manual);

    return Commander.Result.borrowed(.{ .simple_string = switch (outcome) {
        .started => "Background saving started",
        .scheduled => "Background saving scheduled",
    } });
}

fn deinit(ptr: *anyopaque) void {
    const self: *BgSave = @ptrCast(@alignCast(ptr));
    self.allocator.destroy(self);
}
