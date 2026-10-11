const std = @import("std");
const ConnectionReport = @import("report.zig");

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
