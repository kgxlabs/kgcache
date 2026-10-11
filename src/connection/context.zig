const std = @import("std");
const ConnectionReport = @import("report.zig");
const protocol = @import("../protocol.zig");

const ConnectionContext = @This();

pub const Error = std.mem.Allocator.Error;

pub const Snapshot = struct {
    id: u64,
    peer_endpoint: std.Io.net.IpAddress,
    local_endpoint: std.Io.net.IpAddress,
    descriptor: std.Io.net.Socket.Handle,
    registered_at: std.Io.Timestamp,
    sampled_at: std.Io.Timestamp,
    report: ConnectionReport.Snapshot,

    pub fn deinit(self: *Snapshot) void {
        self.report.deinit();
        self.* = undefined;
    }
};

id: u64,
ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    snapshot_current: *const fn (*anyopaque, std.Io, std.mem.Allocator) Error!Snapshot,
    record_read: *const fn (*anyopaque, u64, std.Io.Timestamp) void,
    record_write: *const fn (*anyopaque, u64, std.Io.Timestamp) void,
    record_dispatch: *const fn (*anyopaque, []const u8) void,
    record_db_and_proto: *const fn (*anyopaque, u32, protocol.Resp.Version) void,
};

pub fn snapshotCurrent(self: *const ConnectionContext, io: std.Io, allocator: std.mem.Allocator) Error!Snapshot {
    return self.vtable.snapshot_current(self.ptr, io, allocator);
}

pub fn recordRead(self: *const ConnectionContext, io: std.Io, byte_count: u64) void {
    if (byte_count == 0) return;

    self.vtable.record_read(self.ptr, byte_count, std.Io.Clock.awake.now(io));
}

pub fn recordWrite(self: *const ConnectionContext, io: std.Io, byte_count: u64) void {
    if (byte_count == 0) return;

    self.vtable.record_write(self.ptr, byte_count, std.Io.Clock.awake.now(io));
}

pub fn recordDispatch(self: *const ConnectionContext, canonical_name: []const u8) void {
    self.vtable.record_dispatch(self.ptr, canonical_name);
}

pub fn recordDbAndProto(self: *const ConnectionContext, db_index: u32, resp: protocol.Resp.Version) void {
    self.vtable.record_db_and_proto(self.ptr, db_index, resp);
}
