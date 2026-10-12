const std = @import("std");
const connection = @import("../../connection.zig");
const store = @import("../../store.zig");
const Commander = @import("../interface.zig");
const ClientInfo = @import("client_info.zig");

const ClientList = @This();

allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator, _: []const []const u8) Commander.Error!Commander {
    const self = try allocator.create(ClientList);
    self.* = .{ .allocator = allocator };
    return .{ .ptr = self, .vtable = &vtable };
}

const vtable: Commander.VTable = .{ .execute = execute, .deinit = deinit };

fn execute(ptr: *anyopaque, io: std.Io, _: *store.Store, state: *Commander.ClientState) anyerror!Commander.Result {
    const self: *ClientList = @ptrCast(@alignCast(ptr));
    const context = state.connection_context orelse return error.MissingConnectionContext;

    const arena = try self.allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(self.allocator);
    errdefer {
        arena.deinit();
        self.allocator.destroy(arena);
    }

    var snapshots = try context.snapshotLive(io, arena.allocator());
    defer snapshots.deinit();
    std.mem.sort(connection.ConnectionContext.Snapshot, snapshots.items, {}, struct {
        fn lessThan(_: void, left: connection.ConnectionContext.Snapshot, right: connection.ConnectionContext.Snapshot) bool {
            return left.id < right.id;
        }
    }.lessThan);

    var text: std.ArrayList(u8) = .empty;
    for (snapshots.items) |snapshot| {
        try text.appendSlice(arena.allocator(), try ClientInfo.formatReport(arena.allocator(), snapshot));
    }
    return Commander.Result.inArena(.{ .verbatim = try text.toOwnedSlice(arena.allocator()) }, arena);
}

fn deinit(ptr: *anyopaque) void {
    const self: *ClientList = @ptrCast(@alignCast(ptr));
    self.allocator.destroy(self);
}
