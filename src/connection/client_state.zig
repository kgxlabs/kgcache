const std = @import("std");
const protocol = @import("../protocol.zig");
const ClientRegistry = @import("client_registry.zig");
const ConnectionReport = @import("report.zig");

const ClientState = @This();

pub const ConnectionError = error{MissingConnectionContext};
pub const Error = std.mem.Allocator.Error || ConnectionError;

_db_index: u32 = 0,
_resp: protocol.Resp = protocol.Resp2.resp(),
_live_connection: ?LiveConnection = null,

const LiveConnection = struct {
    metadata: Metadata,
    registry: *ClientRegistry,
    report: ConnectionReport,
};

pub const Metadata = struct {
    id: u64,
    peer_endpoint: std.Io.net.IpAddress,
    local_endpoint: std.Io.net.IpAddress,
    descriptor: std.Io.net.Socket.Handle,
    registered_at: std.Io.Timestamp,
};

pub const LiveConfig = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    registry: *ClientRegistry,
    metadata: Metadata,
};

pub const InitConfig = union(enum) {
    detached,
    live: LiveConfig,
};

pub fn init(_: InitConfig) void {
    @panic("ClientState.init is not implemented");
}

pub fn deinit(_: *ClientState) void {
    @panic("ClientState.deinit is not implemented");
}

pub fn dbIndex(_: *const ClientState) u32 {
    @panic("ClientState.dbIndex is not implemented");
}

pub fn resp(_: *const ClientState) protocol.Resp {
    @panic("ClientState.resp is not implemented");
}

pub fn selectDb(_: *ClientState, _: u32) void {
    @panic("ClientState.selectDb is not implemented");
}

pub fn selectResp(_: *ClientState, _: protocol.Resp) void {
    @panic("ClientState.selectResp is not implemented");
}

pub fn connectionId(_: *const ClientState) ConnectionError!u64 {
    @panic("ClientState.connectionId is not implemented");
}

pub fn snapshotCurrent(_: *ClientState, _: std.Io, _: std.mem.Allocator) Error!Snapshot {
    @panic("ClientState.snapshotCurrent is not implemented");
}

pub fn snapshotLive(_: *const ClientState, _: std.Io, _: std.mem.Allocator) Error!LiveSnapshots {
    @panic("ClientState.snapshotLive is not implemented");
}

pub fn setLibraryInfo(_: *ClientState, _: ConnectionReport.LibraryAttribute, _: []const u8) Error!void {
    @panic("ClientState.setLibraryInfo is not implemented");
}

pub fn recordRead(_: *ClientState, _: std.Io, _: u64) void {
    @panic("ClientState.recordRead is not implemented");
}

pub fn recordWrite(_: *ClientState, _: std.Io, _: u64) void {
    @panic("ClientState.recordWrite is not implemented");
}

pub fn recordDispatch(_: *ClientState, _: []const u8) void {
    @panic("ClientState.recordDispatch is not implemented");
}

pub const Snapshot = struct {
    id: u64,
    peer_endpoint: std.Io.net.IpAddress,
    local_endpoint: std.Io.net.IpAddress,
    descriptor: std.Io.net.Socket.Handle,
    registered_at: std.Io.Timestamp,
    sampled_at: std.Io.Timestamp,
    report: ConnectionReport.Snapshot,

    pub fn deinit(_: *Snapshot) void {
        @panic("ClientState.Snapshot.deinit is not implemented");
    }
};

pub const LiveSnapshots = struct {
    items: []Snapshot,
    allocator: std.mem.Allocator,

    pub fn deinit(_: *LiveSnapshots) void {
        @panic("ClientState.LiveSnapshots.deinit is not implemented");
    }
};
