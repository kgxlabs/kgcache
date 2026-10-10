const std = @import("std");
const build_options = @import("build_options");
const protocol = @import("../protocol.zig");
const store = @import("../store.zig");
const Commander = @import("interface.zig");

const Hello = @This();

allocator: std.mem.Allocator,
arguments: []const []const u8,

pub fn commander(self: *Hello) Commander {
    return .{ .ptr = self, .vtable = &vtable };
}

const vtable: Commander.VTable = .{ .execute = execute, .deinit = deinit };

fn execute(ptr: *anyopaque, _: std.Io, _: *store.Store, state: *Commander.ClientState) anyerror!Commander.Result {
    const self: *Hello = @ptrCast(@alignCast(ptr));
    if (self.arguments.len != 0) return error.UnsupportedOption;

    const context = state.connection_context orelse return error.MissingConnectionContext;

    const arena = try self.allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(self.allocator);
    errdefer {
        arena.deinit();
        self.allocator.destroy(arena);
    }

    const entries = try arena.allocator().dupe(protocol.MapEntry, &.{
        .{ .key = .{ .blob_string = "server" }, .value = .{ .blob_string = "kgcache" } },
        .{ .key = .{ .blob_string = "version" }, .value = .{ .blob_string = build_options.version } },
        .{ .key = .{ .blob_string = "proto" }, .value = .{ .integer = @intFromEnum(state.resp.version()) } },
        .{ .key = .{ .blob_string = "id" }, .value = .{ .integer = @intCast(context.id) } },
        .{ .key = .{ .blob_string = "mode" }, .value = .{ .blob_string = "standalone" } },
        .{ .key = .{ .blob_string = "role" }, .value = .{ .blob_string = "master" } },
        .{ .key = .{ .blob_string = "modules" }, .value = .{ .array = &.{} } },
    });

    return Commander.Result.inArena(.{ .map = entries }, arena);
}

fn deinit(ptr: *anyopaque) void {
    const self: *Hello = @ptrCast(@alignCast(ptr));
    self.allocator.destroy(self);
}
