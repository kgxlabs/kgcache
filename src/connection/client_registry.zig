const std = @import("std");
const ClientState = @import("client_state.zig");
const Lock = @import("../lock.zig");

const ClientRegistry = @This();
_lock: Lock,
// Borrows client pointers. Sessions unregister before freeing their clients.
_clients: std.AutoHashMap(u64, *ClientState),

pub const RegisterError = std.mem.Allocator.Error || ClientState.ConnectionError || error{
    DuplicateConnectionId,
};

pub const SnapshotError = std.mem.Allocator.Error;

pub fn init(
    io: std.Io,
    allocator: std.mem.Allocator,
) ClientRegistry {
    return .{
        ._lock = Lock.init(io),
        ._clients = .init(allocator),
    };
}

pub fn register(
    _: *ClientRegistry,
    _: *ClientState,
) RegisterError!void {
    @panic("ClientRegistry.register is not implemented");
}

pub fn unregister(
    _: *ClientRegistry,
    _: u64,
) void {
    @panic("ClientRegistry.unregister is not implemented");
}

pub fn snapshotLive(
    _: *ClientRegistry,
    _: std.Io,
    _: std.mem.Allocator,
) SnapshotError!ClientState.LiveSnapshots {
    @panic("ClientRegistry.snapshotLive is not implemented");
}

pub fn deinit(_: *ClientRegistry) void {
    @panic("ClientRegistry.deinit is not implemented");
}
