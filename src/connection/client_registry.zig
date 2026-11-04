const std = @import("std");
const ConnectionContext = @import("context.zig");
const ConnectionReport = @import("report.zig");
const Lock = @import("../lock.zig");

const ClientRegistry = @This();
_allocator: std.mem.Allocator,
_lock: Lock,
records: std.AutoHashMap(u64, *ClientRecord),

pub const ClientRecord = struct {
    id: u64,
    peer_endpoint: std.Io.net.IpAddress,
    local_endpoint: std.Io.net.IpAddress,
    descriptor: std.Io.net.Socket.Handle,
    registered_at: std.Io.Timestamp,
    report: ConnectionReport,
};

const Metadata = struct {
    id: u64,
    peer_endpoint: std.Io.net.IpAddress,
    local_endpoint: std.Io.net.IpAddress,
    descriptor: std.Io.net.Socket.Handle,
    registered_at: std.Io.Timestamp,
};

pub const RegisterError = std.mem.Allocator.Error || error{
    DuplicateConnectionId,
};

pub fn init(
    io: std.Io,
    allocator: std.mem.Allocator,
) ClientRegistry {
    return .{
        ._allocator = allocator,
        ._lock = Lock.init(io),
        ._records = .init(allocator),
    };
}

pub fn register(
    _: *ClientRegistry,
    _: std.Io,
    _: Metadata,
) RegisterError!*ClientRecord {
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
) ConnectionContext.Error!ConnectionContext.LiveSnapshots {
    @panic("ClientRegistry.snapshotLive is not implemented");
}

pub fn deinit(_: *ClientRegistry) void {
    @panic("ClientRegistry.deinit is not implemented");
}
