const std = @import("std");
const store = @import("../../store.zig");
const Commander = @import("../interface.zig");
const registry = @import("../registry.zig");

const CommandCount = @This();

allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator, _: []const []const u8) Commander.Error!Commander {
    const self = try allocator.create(CommandCount);
    self.* = .{ .allocator = allocator };
    return .{ .ptr = self, .vtable = &vtable };
}

const vtable: Commander.VTable = .{ .execute = execute, .deinit = deinit };

fn execute(_: *anyopaque, _: std.Io, _: *store.Store, _: *Commander.ClientState) Commander.Error!Commander.Result {
    return Commander.Result.borrowed(.{ .integer = @intCast(registry.all().len) });
}

fn deinit(ptr: *anyopaque) void {
    const self: *CommandCount = @ptrCast(@alignCast(ptr));
    self.allocator.destroy(self);
}
