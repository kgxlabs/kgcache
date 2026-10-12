const std = @import("std");
const store = @import("../../store.zig");
const Commander = @import("../interface.zig");
const replies = @import("replies.zig");

const CommandGetkeys = @This();

allocator: std.mem.Allocator,
arguments: []const []const u8,

pub fn init(allocator: std.mem.Allocator, arguments: []const []const u8) Commander.Error!Commander {
    const self = try allocator.create(CommandGetkeys);
    self.* = .{ .allocator = allocator, .arguments = arguments };
    return .{ .ptr = self, .vtable = &vtable };
}

const vtable: Commander.VTable = .{ .execute = execute, .deinit = deinit };

fn execute(ptr: *anyopaque, _: std.Io, _: *store.Store, _: *Commander.ClientState) Commander.Error!Commander.Result {
    const self: *CommandGetkeys = @ptrCast(@alignCast(ptr));
    return replies.reply(self.allocator, .getkeys, self.arguments[1..]);
}

fn deinit(ptr: *anyopaque) void {
    const self: *CommandGetkeys = @ptrCast(@alignCast(ptr));
    self.allocator.destroy(self);
}
