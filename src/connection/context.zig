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
