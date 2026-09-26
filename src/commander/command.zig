const std = @import("std");
const resp = @import("../resp.zig");
const store = @import("../store.zig");
const Commander = @import("interface.zig");

const Command = @This();

const Subcommand = enum {
    count,
    list,
    info,
    getkeys,
    getkeysandflags,
};

allocator: std.mem.Allocator,
arguments: []resp.RESPValue,

pub fn commander(self: *Command) Commander {
    return .{ .ptr = self, .vtable = &vtable };
}

const vtable = Commander.VTable{ .execute = execute, .deinit = deinit };

fn execute(ptr: *anyopaque, _: std.Io, _: *store.Store, _: *Commander.ClientState) Commander.Error!Commander.Result {
    const self: *Command = @ptrCast(@alignCast(ptr));

    // TODO: Implement introspection.
    return Commander.Result.borrowed(self.arguments[0]);
}

fn executeSubcommand(_: *Command, _: Subcommand) Commander.Error!Commander.Result {
    return error.UnsupportedOption;
}

fn deinit(ptr: *anyopaque) void {
    const self: *Command = @ptrCast(@alignCast(ptr));
    self.allocator.destroy(self);
}
