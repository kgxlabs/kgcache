const std = @import("std");
const ConnectionReport = @import("../connection.zig").ConnectionReport;
const protocol = @import("../protocol.zig");
const testing = std.testing;

test "report counters saturate and only successful byte transfers advance activity" {
    const initial: std.Io.Timestamp = .fromNanoseconds(100);
    var report = ConnectionReport.init(testing.io, initial);
    {
        var tx = try report._lock.begin();
        defer tx.end();
        report._values.total_net_in = std.math.maxInt(u64) - 1;
        report._values.total_net_out = std.math.maxInt(u64) - 2;
        report._values.total_cmds = std.math.maxInt(u64) - 1;
    }
    report.recordRead(0, .fromNanoseconds(1000));
    report.recordWrite(0, .fromNanoseconds(1000));
    report.recordDispatch("hello");
    report.recordDbAndProto(7, .resp3);
    {
        var tx = try report._lock.begin();
        defer tx.end();
        try testing.expectEqual(initial, report._values.last_activity);
    }
    report.recordRead(2, .fromNanoseconds(200));
    report.recordWrite(3, .fromNanoseconds(300));
    report.recordRead(std.math.maxInt(u64), .fromNanoseconds(250));
    report.recordWrite(std.math.maxInt(u64), .fromNanoseconds(290));
    report.recordDispatch("client|info");
    report.recordDispatch("ping");

    var tx = try report._lock.begin();
    defer tx.end();
    const values = report._values;
    try testing.expectEqual(std.math.maxInt(u64), values.total_net_in);
    try testing.expectEqual(std.math.maxInt(u64), values.total_net_out);
    try testing.expectEqual(std.math.maxInt(u64), values.total_cmds);
    try testing.expectEqual(std.Io.Timestamp.fromNanoseconds(300), values.last_activity);
    try testing.expectEqualStrings("ping", values.last_command);
    try testing.expectEqual(7, values.db_index);
    try testing.expectEqual(protocol.Resp.Version.resp3, values.resp);
}

test "concurrent report updates preserve totals and a coherent published state" {
    const iterations = 1000;
    const worker_count = 4;
    const Worker = struct {
        report: *ConnectionReport,
        db_index: u32,
        resp: protocol.Resp.Version,

        fn run(self: *@This()) void {
            for (0..iterations) |_| {
                self.report.recordRead(7, .fromNanoseconds(200));
                self.report.recordWrite(11, .fromNanoseconds(300));
                self.report.recordDispatch("get");
                self.report.recordDbAndProto(self.db_index, self.resp);
            }
        }
    };
    var report = ConnectionReport.init(testing.io, .fromNanoseconds(100));
    var workers: [worker_count]Worker = undefined;
    var threads: [worker_count]std.Thread = undefined;
    var started: usize = 0;
    defer for (threads[0..started]) |thread| thread.join();
    for (&workers, &threads, 0..) |*worker, *thread, index| {
        worker.* = .{
            .report = &report,
            .db_index = if (index % 2 == 0) 2 else 3,
            .resp = if (index % 2 == 0) .resp2 else .resp3,
        };
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{worker});
        started += 1;
    }
    for (0..iterations) |_| {
        var tx = try report._lock.begin();
        defer tx.end();
        const values = report._values;
        try testing.expect((values.db_index == 0 and values.resp == .resp2) or
            (values.db_index == 2 and values.resp == .resp2) or
            (values.db_index == 3 and values.resp == .resp3));
        try testing.expectEqualStrings(if (values.total_cmds == 0) "NULL" else "get", values.last_command);
    }
    for (threads) |thread| thread.join();
    started = 0;

    var tx = try report._lock.begin();
    defer tx.end();
    try testing.expectEqual(worker_count * iterations * 7, report._values.total_net_in);
    try testing.expectEqual(worker_count * iterations * 11, report._values.total_net_out);
    try testing.expectEqual(worker_count * iterations, report._values.total_cmds);
    try testing.expectEqual(std.Io.Timestamp.fromNanoseconds(300), report._values.last_activity);
}
