const std = @import("std");
const ConnectionReport = @import("../connection.zig").ConnectionReport;
const protocol = @import("../protocol.zig");
const testing = std.testing;

test "report counters saturate and only successful byte transfers advance activity" {
    const initial: std.Io.Timestamp = .fromNanoseconds(100);
    var report = ConnectionReport.init(testing.io, testing.allocator, initial);
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
    var report = ConnectionReport.init(testing.io, testing.allocator, .fromNanoseconds(100));
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

test "report snapshots own their strings and survive changes to the source" {
    var request_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer request_arena.deinit();

    var snapshot = captured: {
        var report = ConnectionReport.init(testing.io, testing.allocator, .fromNanoseconds(100));
        const lib_name = try testing.allocator.dupe(u8, "test-library");
        defer testing.allocator.free(lib_name);
        const lib_ver = try testing.allocator.dupe(u8, "1.2.3");
        defer testing.allocator.free(lib_ver);
        report._values.lib_name = lib_name;
        report._values.lib_ver = lib_ver;
        report.recordDbAndProto(7, .resp3);
        report.recordRead(12, .fromNanoseconds(200));
        report.recordWrite(34, .fromNanoseconds(300));
        report.recordDispatch("client|info");

        var owned = try report.snapshot(request_arena.allocator());
        errdefer owned.deinit();
        try expectReportUnlocked(&report);
        try testing.expect(owned.values.last_command.ptr != report._values.last_command.ptr);
        try testing.expect(owned.values.lib_name.ptr != lib_name.ptr);
        try testing.expect(owned.values.lib_ver.ptr != lib_ver.ptr);

        report.recordDbAndProto(2, .resp2);
        report.recordRead(100, .fromNanoseconds(400));
        report.recordDispatch("get");
        {
            var tx = report._lock.beginUncancelable();
            defer tx.end();
            report._values.lib_name = "";
            report._values.lib_ver = "";
        }
        @memset(lib_name, 'x');
        @memset(lib_ver, 'x');
        break :captured owned;
    };
    defer snapshot.deinit();

    const values = snapshot.values;
    try testing.expectEqual(7, values.db_index);
    try testing.expectEqual(protocol.Resp.Version.resp3, values.resp);
    try testing.expectEqualStrings("client|info", values.last_command);
    try testing.expectEqualStrings("test-library", values.lib_name);
    try testing.expectEqualStrings("1.2.3", values.lib_ver);
    try testing.expectEqual(12, values.total_net_in);
    try testing.expectEqual(34, values.total_net_out);
    try testing.expectEqual(1, values.total_cmds);
    try testing.expectEqual(std.Io.Timestamp.fromNanoseconds(300), values.last_activity);
}

test "snapshot allocation failures release copied strings and the report lock" {
    try testing.checkAllAllocationFailures(testing.allocator, snapshotAllocation, .{});
}

fn snapshotAllocation(allocator: std.mem.Allocator) !void {
    var report = ConnectionReport.init(testing.io, testing.allocator, .fromNanoseconds(100));
    report._values.lib_name = "test-library";
    report._values.lib_ver = "1.2.3";
    report.recordDbAndProto(7, .resp3);
    report.recordDispatch("client|info");

    var snapshot = report.snapshot(allocator) catch |err| {
        try expectReportUnlocked(&report);
        try testing.expectEqualStrings("test-library", report._values.lib_name);
        try testing.expectEqualStrings("1.2.3", report._values.lib_ver);
        try testing.expectEqualStrings("client|info", report._values.last_command);
        try testing.expectEqual(7, report._values.db_index);
        try testing.expectEqual(protocol.Resp.Version.resp3, report._values.resp);
        return err;
    };
    defer snapshot.deinit();
    try expectReportUnlocked(&report);
    try testing.expectEqualStrings("test-library", snapshot.values.lib_name);
    try testing.expectEqualStrings("1.2.3", snapshot.values.lib_ver);
    try testing.expectEqualStrings("client|info", snapshot.values.last_command);
}

fn expectReportUnlocked(report: *ConnectionReport) !void {
    var tx = report._lock.tryBegin() orelse return error.ReportLockStillHeld;
    tx.end();
}

test "owned labels survive failed replacement and snapshots survive replacement and clearing" {
    try testing.checkAllAllocationFailures(testing.allocator, libraryAllocation, .{});
}

fn libraryAllocation(allocator: std.mem.Allocator) !void {
    var report = ConnectionReport.init(testing.io, allocator, .fromNanoseconds(100));
    defer report.deinit();
    try report.setLibraryInfo(.lib_name, "OldName");
    try report.setLibraryInfo(.lib_ver, "OldVersion");
    var old = try report.snapshot(testing.allocator);
    defer old.deinit();
    report.setLibraryInfo(.lib_name, "NewName") catch |err| {
        try expectReportUnlocked(&report);
        try testing.expectEqualStrings("OldName", report._values.lib_name);
        try testing.expectEqualStrings("OldVersion", report._values.lib_ver);
        return err;
    };
    try report.setLibraryInfo(.lib_ver, "");
    var current = try report.snapshot(allocator);
    defer current.deinit();
    try report.setLibraryInfo(.lib_name, "");
    try testing.expectEqualStrings("OldName", old.values.lib_name);
    try testing.expectEqualStrings("OldVersion", old.values.lib_ver);
    try testing.expectEqualStrings("NewName", current.values.lib_name);
    try testing.expectEqualStrings("", current.values.lib_ver);
    try testing.expectEqualStrings("", report._values.lib_name);
    try testing.expectEqualStrings("", report._values.lib_ver);
    try expectReportUnlocked(&report);
}

test "concurrent snapshots remain valid while owned labels are replaced" {
    const Updater = struct {
        report: *ConnectionReport,
        started: std.Io.Event = .unset,
        stop: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            var first = true;
            while (!self.stop.load(.acquire)) {
                self.report.setLibraryInfo(.lib_name, if (first) "First" else "LongerSecondName") catch unreachable;
                self.started.set(testing.io);
                first = !first;
            }
        }
    };
    var report = ConnectionReport.init(testing.io, testing.allocator, .fromNanoseconds(100));
    defer report.deinit();
    try report.setLibraryInfo(.lib_ver, "V1");
    var updater: Updater = .{ .report = &report };
    const thread = try std.Thread.spawn(.{}, Updater.run, .{&updater});
    defer {
        updater.stop.store(true, .release);
        thread.join();
    }
    updater.started.waitUncancelable(testing.io);
    for (0..1000) |_| {
        var snapshot = try report.snapshot(testing.allocator);
        defer snapshot.deinit();
        try testing.expect(std.mem.eql(u8, snapshot.values.lib_name, "First") or std.mem.eql(u8, snapshot.values.lib_name, "LongerSecondName"));
        try testing.expectEqualStrings("V1", snapshot.values.lib_ver);
    }
}

test "concurrent snapshots copy coherent report rows" {
    const iterations = 1000;
    const Updater = struct {
        report: *ConnectionReport,
        started: std.Io.Event = .unset,
        stop_requested: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            var first = true;
            while (!self.stop_requested.load(.acquire)) {
                {
                    var tx = self.report._lock.beginUncancelable();
                    defer tx.end();
                    self.report._values = .{
                        .last_activity = .fromNanoseconds(if (first) 200 else 300),
                        .db_index = if (first) 2 else 3,
                        .resp = if (first) .resp2 else .resp3,
                        .last_command = if (first) "get" else "hello",
                        .lib_name = if (first) "first-library" else "second-library",
                        .lib_ver = if (first) "1" else "2",
                        .total_net_in = if (first) 11 else 22,
                        .total_net_out = if (first) 33 else 44,
                        .total_cmds = if (first) 5 else 6,
                    };
                }
                self.started.set(testing.io);
                first = !first;
            }
        }
    };

    var report = ConnectionReport.init(testing.io, testing.allocator, .fromNanoseconds(100));
    var updater: Updater = .{ .report = &report };
    const thread = try std.Thread.spawn(.{}, Updater.run, .{&updater});
    defer {
        updater.stop_requested.store(true, .release);
        thread.join();
    }
    updater.started.waitUncancelable(testing.io);
    for (0..iterations) |_| {
        var snapshot = try report.snapshot(testing.allocator);
        defer snapshot.deinit();
        const values = snapshot.values;
        try testing.expect(values.db_index == 2 or values.db_index == 3);
        const first = values.db_index == 2;
        try testing.expectEqual(if (first) protocol.Resp.Version.resp2 else .resp3, values.resp);
        try testing.expectEqualStrings(if (first) "get" else "hello", values.last_command);
        try testing.expectEqualStrings(if (first) "first-library" else "second-library", values.lib_name);
        try testing.expectEqualStrings(if (first) "1" else "2", values.lib_ver);
        try testing.expectEqual(@as(u64, if (first) 11 else 22), values.total_net_in);
        try testing.expectEqual(@as(u64, if (first) 33 else 44), values.total_net_out);
        try testing.expectEqual(@as(u64, if (first) 5 else 6), values.total_cmds);
        try testing.expectEqual(std.Io.Timestamp.fromNanoseconds(if (first) 200 else 300), values.last_activity);
    }
}
