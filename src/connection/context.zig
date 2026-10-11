const std = @import("std");
const ReportAccess = @import("report_access.zig");

const ConnectionContext = @This();

pub const Error = ReportAccess.Error || error{MissingReportAccess};

id: u64,
reports: ?ReportAccess = null,

pub fn snapshotCurrent(self: *const ConnectionContext, io: std.Io, allocator: std.mem.Allocator) Error!ReportAccess.Snapshot {
    const reports = self.reports orelse return error.MissingReportAccess;
    return reports.snapshotCurrent(io, allocator);
}

pub fn recordRead(self: *const ConnectionContext, io: std.Io, byte_count: u64) void {
    if (byte_count == 0) return;

    const reports = self.reports orelse return;

    reports.recordRead(byte_count, std.Io.Clock.awake.now(io));
}

pub fn recordWrite(self: *const ConnectionContext, io: std.Io, byte_count: u64) void {
    if (byte_count == 0) return;

    const reports = self.reports orelse return;

    reports.recordWrite(byte_count, std.Io.Clock.awake.now(io));
}
