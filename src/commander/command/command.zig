const std = @import("std");
const store = @import("../../store.zig");
const Commander = @import("../interface.zig");
const replies = @import("replies.zig");

const Command = @This();

allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator, _: []const []const u8) Commander.Error!Commander {
    const self = try allocator.create(Command);
    self.* = .{ .allocator = allocator };
    return .{ .ptr = self, .vtable = &vtable };
}

const vtable: Commander.VTable = .{ .execute = execute, .deinit = deinit };

fn execute(ptr: *anyopaque, _: std.Io, _: *store.Store, _: *Commander.ClientState) Commander.Error!Commander.Result {
    const self: *Command = @ptrCast(@alignCast(ptr));
    return replies.reply(self.allocator, .all, &.{});
}

fn deinit(ptr: *anyopaque) void {
    const self: *Command = @ptrCast(@alignCast(ptr));
    self.allocator.destroy(self);
}
