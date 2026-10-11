const std = @import("std");
const ConnectionReport = @import("report.zig");

const ReportAccess = @This();

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

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    snapshot_current: *const fn (*anyopaque, std.Io, std.mem.Allocator) Error!Snapshot,
    record_read: *const fn (*anyopaque, u64, std.Io.Timestamp) void,
    record_write: *const fn (*anyopaque, u64, std.Io.Timestamp) void,
};

pub fn snapshotCurrent(self: ReportAccess, io: std.Io, allocator: std.mem.Allocator) Error!Snapshot {
    return self.vtable.snapshot_current(self.ptr, io, allocator);
}

pub fn recordRead(self: ReportAccess, byte_count: u64, at: std.Io.Timestamp) void {
    self.vtable.record_read(self.ptr, byte_count, at);
}

pub fn recordWrite(self: ReportAccess, byte_count: u64, at: std.Io.Timestamp) void {
    self.vtable.record_write(self.ptr, byte_count, at);
}
