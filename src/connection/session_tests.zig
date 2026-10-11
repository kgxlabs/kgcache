const std = @import("std");
const store = @import("../store.zig");
const logging = @import("../logger.zig");
const serve = @import("../connection.zig").serve;
const ConnectionContext = @import("../connection.zig").ConnectionContext;
const ClientWorker = @import("manager.zig").ClientWorker;
const ConnectionReport = @import("report.zig");
const TestNetwork = @import("test_network.zig");

const test_connection_context = TestNetwork.identityContext(1);
const never_stop_requested: std.atomic.Value(bool) = .init(false);

test "buffer allocation failure is reported once without closing the borrowed stream" {
    const CloseRecorder = struct {
        calls: usize = 0,

        fn close(userdata: ?*anyopaque, handles: []const std.Io.net.Socket.Handle) void {
            const self: *@This() = @ptrCast(@alignCast(userdata));
            self.calls += handles.len;
        }
    };

    var close_recorder: CloseRecorder = .{};
    var io_vtable = std.testing.io.vtable.*;
    io_vtable.netClose = CloseRecorder.close;
    const io: std.Io = .{
        .userdata = &close_recorder,
        .vtable = &io_vtable,
    };

    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 0,
    });
    var test_logger = logging.TestLogger.init();
    var unused_store: store.Store = undefined;

    serve(
        io,
        test_logger.logger(),
        .{ .socket = .{ .handle = 1, .address = undefined } },
        &test_connection_context,
        &unused_store,
        failing_allocator.allocator(),
        1024,
        &never_stop_requested,
    );

    const events = test_logger.recordedEvents();
    try std.testing.expectEqual(1, events.len);
    try std.testing.expectEqual(logging.TestLogger.Event.Kind.err, events[0].kind);
    try std.testing.expectEqual(error.OutOfMemory, events[0].source.?);
    try std.testing.expectEqual(0, close_recorder.calls);
}

const TestConnectionIo = struct {
    requests: []const []const u8,
    next_request: usize = 0,
    request_offset: usize = 0,
    output: [2048]u8 = undefined,
    output_len: usize = 0,
    close_calls: usize = 0,
    read_error: ?std.Io.net.Stream.Reader.Error = null,
    fail_write: bool = false,
    write_error: std.Io.net.Stream.Writer.Error = error.NetworkDown,
    fail_after_bytes: ?usize = null,
    max_write_bytes: usize = std.math.maxInt(usize),
    pause_after_bytes: ?usize = null,
    write_paused: std.Io.Event = .unset,
    continue_write: std.Io.Event = .unset,
    stop_after_read: ?*std.atomic.Value(bool) = null,
    stop_during_write: ?*std.atomic.Value(bool) = null,
    transport_time_ns: i96 = 100,
    time_step_ns: i96 = 1,
    awake_samples: usize = 0,
    zero_writes: usize = 0,
    vtable: std.Io.VTable = undefined,

    fn io(self: *@This()) std.Io {
        self.vtable = std.testing.io.vtable.*;
        self.vtable.netRead = read;
        self.vtable.netWrite = write;
        self.vtable.netClose = close;
        self.vtable.now = now;
        return .{ .userdata = self, .vtable = &self.vtable };
    }

    fn read(ptr: ?*anyopaque, _: std.Io.net.Socket.Handle, data: [][]u8) std.Io.net.Stream.Reader.Error!usize {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.transport_time_ns += self.time_step_ns;
        if (self.next_request == self.requests.len) {
            if (self.read_error) |err| return err;
            return 0;
        }
        const request = self.requests[self.next_request];
        std.debug.assert(data[0].len > 0);
        const count = @min(request.len - self.request_offset, data[0].len);
        @memcpy(data[0][0..count], request[self.request_offset..][0..count]);
        self.request_offset += count;
        if (self.request_offset == request.len) {
            self.next_request += 1;
            self.request_offset = 0;
        }
        if (self.stop_after_read) |flag| flag.store(true, .release);
        return count;
    }

    fn write(ptr: ?*anyopaque, _: std.Io.net.Socket.Handle, header: []const u8, data: []const []const u8, splat: usize) std.Io.net.Stream.Writer.Error!usize {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.transport_time_ns += self.time_step_ns;
        if (self.zero_writes > 0) {
            self.zero_writes -= 1;
            return 0;
        }
        if (self.fail_write) return self.write_error;
        if (self.fail_after_bytes) |limit| {
            if (self.output_len >= limit) return self.write_error;
        }
        if (self.pause_after_bytes) |limit| {
            if (self.output_len >= limit and !self.continue_write.isSet()) {
                self.write_paused.set(std.testing.io);
                self.continue_write.waitTimeout(std.testing.io, .{
                    .duration = .{ .raw = .fromSeconds(5), .clock = .awake },
                }) catch return error.NetworkDown;
            }
        }
        if (self.stop_during_write) |flag| flag.store(true, .release);
        var remaining = self.max_write_bytes;
        std.debug.assert(remaining > 0);
        var count = self.append(header, &remaining);
        if (count != header.len) return count;
        for (data[0 .. data.len - 1]) |part| {
            const byte_count = self.append(part, &remaining);
            count += byte_count;
            if (byte_count != part.len) return count;
        }
        if (splat > 0) {
            const part = data[data.len - 1];
            for (0..splat) |_| {
                const byte_count = self.append(part, &remaining);
                count += byte_count;
                if (byte_count != part.len) return count;
            }
        }
        return count;
    }

    fn append(self: *@This(), bytes: []const u8, remaining: *usize) usize {
        var limit = self.fail_after_bytes orelse self.output.len;
        if (!self.continue_write.isSet()) {
            if (self.pause_after_bytes) |pause_limit| limit = @min(limit, pause_limit);
        }
        const count = @min(bytes.len, limit - self.output_len, remaining.*);
        std.debug.assert(self.output_len + count <= self.output.len);
        @memcpy(self.output[self.output_len..][0..count], bytes[0..count]);
        self.output_len += count;
        remaining.* -= count;
        return count;
    }

    fn close(ptr: ?*anyopaque, handles: []const std.Io.net.Socket.Handle) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.close_calls += handles.len;
    }

    fn now(ptr: ?*anyopaque, clock: std.Io.Clock) std.Io.Timestamp {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (clock != .awake) return std.testing.io.vtable.now(std.testing.io.userdata, clock);
        self.awake_samples += 1;
        return .fromNanoseconds(self.transport_time_ns);
    }

    fn written(self: *const @This()) []const u8 {
        return self.output[0..self.output_len];
    }
};

fn initTestWorker(worker: *ClientWorker, registered_at: std.Io.Timestamp) void {
    const peer: std.Io.net.IpAddress = .{ .ip4 = .loopback(40000) };
    worker.* = .{
        .stream = .{ .socket = .{ .handle = 1, .address = peer } },
        .context = worker.connectionContext(1),
        .peer_endpoint = peer,
        .local_endpoint = .{ .ip4 = .loopback(6379) },
        .descriptor = 1,
        .registered_at = registered_at,
        .report = ConnectionReport.init(std.testing.io, registered_at),
    };
}

test "fragmented and retained input counts each received byte once through short writes" {
    const testing = std.testing;
    const request = "*1\r\n$4\r\nPING\r\n" ++
        "*2\r\n$4\r\nECHO\r\n$25\r\napple banana orange grape\r\n" ++
        "*1\r\n$4\r\nPING\r\n*1\r\n$4\r\nPI";
    const expected = "+PONG\r\n$25\r\napple banana orange grape\r\n+PONG\r\n";
    for (1..request.len) |split| {
        var fake_io: TestConnectionIo = .{
            .requests = &.{ request[0..split], request[split..] },
            .max_write_bytes = 2,
            .zero_writes = 3,
        };
        var worker: ClientWorker = undefined;
        initTestWorker(&worker, .fromNanoseconds(100));
        var mock = store.MockStore.init();
        var data_store = mock.store();
        var logger = logging.TestLogger.init();

        serve(fake_io.io(), logger.logger(), worker.stream, &worker.context, &data_store, testing.allocator, 16, &never_stop_requested);

        try testing.expectEqualStrings(expected, fake_io.written());
        var snapshot = try worker.report.snapshot(testing.allocator);
        defer snapshot.deinit();
        try testing.expectEqual(request.len, snapshot.values.total_net_in);
        try testing.expectEqual(expected.len, snapshot.values.total_net_out);
        try testing.expectEqual(3, snapshot.values.total_cmds);
        try testing.expectEqualStrings("ping", snapshot.values.last_command);
        try testing.expectEqual(fake_io.transport_time_ns - fake_io.time_step_ns, snapshot.values.last_activity.nanoseconds);
        try testing.expectEqual(0, logger.recordedEvents().len);
        try testing.expectEqual(0, fake_io.close_calls);
    }
}

test "INFO snapshots include received pipeline tails and exclude their current reply" {
    const testing = std.testing;
    const info = "*2\r\n$6\r\nCLIENT\r\n$4\r\nINFO\r\n";
    const first_read = info ++ "*1\r\n$4\r\nPI";
    var fake_io: TestConnectionIo = .{
        .requests = &.{ first_read, "NG\r\n" },
        .max_write_bytes = 2,
        .transport_time_ns = 9_400_000_000,
        .time_step_ns = 700_000_000,
    };
    var worker: ClientWorker = undefined;
    initTestWorker(&worker, .fromNanoseconds(0));
    var mock = store.MockStore.init();
    var data_store = mock.store();
    var logger = logging.TestLogger.init();

    serve(fake_io.io(), logger.logger(), worker.stream, &worker.context, &data_store, testing.allocator, 1024, &never_stop_requested);

    var buffer: [80]u8 = undefined;
    const counters = try std.fmt.bufPrint(&buffer, " tot-net-in={d} tot-net-out=0 ", .{first_read.len});
    try testing.expect(std.mem.indexOf(u8, fake_io.written(), counters) != null);
    try testing.expect(std.mem.indexOf(u8, fake_io.written(), " age=10 idle=0 ") != null);
    try testing.expect(std.mem.indexOf(u8, fake_io.written(), " cmd=client|info ") != null);
    try testing.expect(std.mem.indexOf(u8, fake_io.written(), " tot-cmds=1 ") != null);
    try testing.expect(std.mem.endsWith(u8, fake_io.written(), "+PONG\r\n"));
    var snapshot = try worker.report.snapshot(testing.allocator);
    defer snapshot.deinit();
    try testing.expectEqual(first_read.len + 4, snapshot.values.total_net_in);
    try testing.expectEqual(fake_io.output_len, snapshot.values.total_net_out);
    try testing.expectEqual(2, snapshot.values.total_cmds);
    try testing.expectEqualStrings("ping", snapshot.values.last_command);
    try testing.expectEqual(fake_io.transport_time_ns - fake_io.time_step_ns, snapshot.values.last_activity.nanoseconds);
    try testing.expectEqual(0, logger.recordedEvents().len);
}

test "EOF and failed reads leave activity at the last successful transfer" {
    const testing = std.testing;
    for ([_]?std.Io.net.Stream.Reader.Error{ null, error.NetworkDown, error.ConnectionResetByPeer }) |read_error| {
        for ([_]bool{ false, true }) |receive_prefix| {
            var fake_io: TestConnectionIo = .{
                .requests = if (receive_prefix) &.{"*1\r\n"} else &.{},
                .read_error = read_error,
            };
            var worker: ClientWorker = undefined;
            initTestWorker(&worker, .fromNanoseconds(100));
            var mock = store.MockStore.init();
            var data_store = mock.store();
            var logger = logging.TestLogger.init();

            serve(fake_io.io(), logger.logger(), worker.stream, &worker.context, &data_store, testing.allocator, 1024, &never_stop_requested);

            var snapshot = try worker.report.snapshot(testing.allocator);
            defer snapshot.deinit();
            try testing.expectEqual(@as(u64, if (receive_prefix) 4 else 0), snapshot.values.total_net_in);
            try testing.expectEqual(0, snapshot.values.total_net_out);
            try testing.expectEqual(0, snapshot.values.total_cmds);
            try testing.expectEqualStrings("NULL", snapshot.values.last_command);
            try testing.expectEqual(@as(i96, if (receive_prefix) 101 else 100), snapshot.values.last_activity.nanoseconds);
            try testing.expectEqual(@as(usize, if (receive_prefix) 1 else 0), fake_io.awake_samples);
        }
    }
}

test "failed writes retain successful prefixes and ignore zero writes and failure activity" {
    const testing = std.testing;
    const requests = [_][]const u8{
        "*1\r\n$4\r\nPING\r\n*1\r\n$6\r\nDBSIZE\r\n",
        "*2\r\n$6\r\nCLIENT\r\n$4\r\nINFO\r\n*1\r\n$6\r\nDBSIZE\r\n",
    };
    for (requests) |request| {
        for ([_]usize{ 0, 1, 3, 6 }) |prefix_length| {
            var fake_io: TestConnectionIo = .{
                .requests = &.{request},
                .fail_after_bytes = prefix_length,
                .max_write_bytes = 1,
                .zero_writes = 2,
            };
            var worker: ClientWorker = undefined;
            initTestWorker(&worker, .fromNanoseconds(100));
            var mock = store.MockStore.init();
            var data_store = mock.store();
            var logger = logging.TestLogger.init();

            serve(fake_io.io(), logger.logger(), worker.stream, &worker.context, &data_store, testing.allocator, 1024, &never_stop_requested);

            var snapshot = try worker.report.snapshot(testing.allocator);
            defer snapshot.deinit();
            try testing.expectEqual(request.len, snapshot.values.total_net_in);
            try testing.expectEqual(prefix_length, snapshot.values.total_net_out);
            try testing.expectEqual(1, snapshot.values.total_cmds);
            try testing.expectEqualStrings(if (std.mem.startsWith(u8, request, "*2")) "client|info" else "ping", snapshot.values.last_command);
            try testing.expectEqual(prefix_length, fake_io.output_len);
            const last_activity = if (prefix_length == 0) 101 else 103 + @as(i96, @intCast(prefix_length));
            try testing.expectEqual(last_activity, snapshot.values.last_activity.nanoseconds);
            const snapshot_samples: usize = if (std.mem.startsWith(u8, request, "*2")) 1 else 0;
            try testing.expectEqual(1 + prefix_length + snapshot_samples, fake_io.awake_samples);
            try testing.expectEqual(0, mock.dbsize_calls);
            try testing.expectEqual(0, fake_io.close_calls);
            try testing.expectEqual(1, logger.recordedEvents().len);
            try testing.expectEqual(error.NetworkDown, logger.recordedEvents()[0].source.?);
        }
    }
}

test "network byte and dispatch totals saturate while canonical names keep updating" {
    const testing = std.testing;
    var fake_io: TestConnectionIo = .{ .requests = &.{"*2\r\n$6\r\nCLIENT\r\n$4\r\nINFO\r\n*1\r\n$4\r\nPING\r\n"}, .max_write_bytes = 2 };
    var worker: ClientWorker = undefined;
    initTestWorker(&worker, .fromNanoseconds(100));
    const max = std.math.maxInt(u64);
    worker.report._values.total_net_in = max - 1;
    worker.report._values.total_net_out = max - 1;
    worker.report._values.total_cmds = max - 1;
    var mock = store.MockStore.init();
    var data_store = mock.store();
    var logger = logging.TestLogger.init();

    serve(fake_io.io(), logger.logger(), worker.stream, &worker.context, &data_store, testing.allocator, 1024, &never_stop_requested);

    try testing.expect(std.mem.indexOf(u8, fake_io.written(), " tot-net-in=18446744073709551615 tot-net-out=18446744073709551614 tot-cmds=18446744073709551615 ") != null);
    var snapshot = try worker.report.snapshot(testing.allocator);
    defer snapshot.deinit();
    try testing.expectEqual(max, snapshot.values.total_net_in);
    try testing.expectEqual(max, snapshot.values.total_net_out);
    try testing.expectEqual(max, snapshot.values.total_cmds);
    try testing.expectEqualStrings("ping", snapshot.values.last_command);
    try testing.expectEqual(0, logger.recordedEvents().len);
}

test "rejected bindings and undecoded input preserve the previous dispatch" {
    const testing = std.testing;
    const cases = [_]struct { request: []const u8, response: []const u8 }{
        .{ .request = "*1\r\n$7\r\nUNKNOWN\r\n", .response = "-ERR unknown command\r\n" },
        .{ .request = "*1\r\n$3\r\nGET\r\n", .response = "-ERR wrong number of arguments\r\n" },
        .{ .request = "*3\r\n$4\r\nPING\r\n$1\r\na\r\n$1\r\nb\r\n", .response = "-ERR wrong number of arguments\r\n" },
        .{ .request = "*1\r\n$6\r\nCLIENT\r\n", .response = "-ERR wrong number of arguments\r\n" },
        .{ .request = "*3\r\n$6\r\nCLIENT\r\n$4\r\nINFO\r\n$1\r\nx\r\n", .response = "-ERR wrong number of arguments\r\n" },
        .{ .request = "*2\r\n$6\r\nCLIENT\r\n$7\r\nUNKNOWN\r\n", .response = "-ERR unsupported option\r\n" },
        .{ .request = "*2\r\n$6\r\nCLIENT\r\n$4\r\nLIST\r\n", .response = "-ERR unsupported option\r\n" },
        .{ .request = "*4\r\n$6\r\nCLIENT\r\n$7\r\nSETINFO\r\n$8\r\nLIB-NAME\r\n$1\r\nx\r\n", .response = "-ERR unsupported option\r\n" },
        .{ .request = "*1\r\n$4\r\nPI", .response = "" },
        .{ .request = "*1\r\n:42\r\n", .response = "-ERR protocol error: invalid RESP type\r\n" },
        .{ .request = "*0\r\n", .response = "-ERR protocol error: malformed request\r\n" },
    };
    for (cases) |case| {
        var fake_io: TestConnectionIo = .{ .requests = &.{case.request} };
        var worker: ClientWorker = undefined;
        initTestWorker(&worker, .fromNanoseconds(100));
        worker.report.recordDispatch("echo");
        var mock = store.MockStore.init();
        var data_store = mock.store();
        var logger = logging.TestLogger.init();

        serve(fake_io.io(), logger.logger(), worker.stream, &worker.context, &data_store, testing.allocator, 1024, &never_stop_requested);

        var snapshot = try worker.report.snapshot(testing.allocator);
        defer snapshot.deinit();
        try testing.expectEqual(1, snapshot.values.total_cmds);
        try testing.expectEqualStrings("echo", snapshot.values.last_command);
        try testing.expectEqualStrings(case.response, fake_io.written());
        try testing.expectEqual(0, logger.recordedEvents().len);
    }
}

test "INFO includes its dispatch after expected handler errors and rejected pipeline requests" {
    const testing = std.testing;
    const request = "*1\r\n$4\r\npInG\r\n" ++
        "*2\r\n$5\r\nhElLo\r\n$1\r\n4\r\n" ++
        "*2\r\n$6\r\nsElEcT\r\n$2\r\n99\r\n" ++
        "*1\r\n$3\r\nGET\r\n" ++
        "*1\r\n$7\r\nUNKNOWN\r\n" ++
        "*2\r\n$6\r\nCLIENT\r\n$7\r\nUNKNOWN\r\n" ++
        "*3\r\n$6\r\nCLIENT\r\n$4\r\nINFO\r\n$1\r\nx\r\n" ++
        "*2\r\n$6\r\ncLiEnT\r\n$4\r\niNfO\r\n" ++
        "*1\r\n$4\r\nPiNg\r\n";
    const previous_replies = "+PONG\r\n" ++
        "-NOPROTO unsupported protocol version\r\n" ++
        "-ERR DB index is out of range\r\n" ++
        "-ERR wrong number of arguments\r\n" ++
        "-ERR unknown command\r\n" ++
        "-ERR unsupported option\r\n" ++
        "-ERR wrong number of arguments\r\n";
    var fake_io: TestConnectionIo = .{ .requests = &.{request}, .max_write_bytes = 2 };
    var worker: ClientWorker = undefined;
    initTestWorker(&worker, .fromNanoseconds(100));
    var mock = store.MockStore.init();
    var data_store = mock.store();
    var logger = logging.TestLogger.init();

    serve(fake_io.io(), logger.logger(), worker.stream, &worker.context, &data_store, testing.allocator, 1024, &never_stop_requested);

    try testing.expect(std.mem.startsWith(u8, fake_io.written(), previous_replies));
    try testing.expect(std.mem.endsWith(u8, fake_io.written(), "+PONG\r\n"));
    try testing.expect(std.mem.indexOf(u8, fake_io.written(), " cmd=client|info ") != null);
    var buffer: [96]u8 = undefined;
    const totals = try std.fmt.bufPrint(&buffer, " tot-net-in={d} tot-net-out={d} tot-cmds=4 ", .{ request.len, previous_replies.len });
    try testing.expect(std.mem.indexOf(u8, fake_io.written(), totals) != null);
    var snapshot = try worker.report.snapshot(testing.allocator);
    defer snapshot.deinit();
    try testing.expectEqual(5, snapshot.values.total_cmds);
    try testing.expectEqualStrings("ping", snapshot.values.last_command);
    try testing.expectEqual(0, mock.get_calls);
    try testing.expectEqual(0, logger.recordedEvents().len);
}

test "pipelined INFO reports the latest valid database and protocol after handler errors" {
    const testing = std.testing;
    for ([_]u8{ 2, 3 }) |version| {
        const next_version: u8 = if (version == 2) 3 else 2;
        const request = try std.fmt.allocPrint(testing.allocator, "*2\r\n$6\r\nsElEcT\r\n$1\r\n1\r\n" ++
            "*2\r\n$5\r\nhElLo\r\n$1\r\n{d}\r\n" ++
            "*3\r\n$5\r\nHELLO\r\n$1\r\n{d}\r\n$4\r\nAUTH\r\n" ++
            "*2\r\n$6\r\nSELECT\r\n$2\r\n99\r\n" ++
            "*2\r\n$5\r\nHELLO\r\n$1\r\n4\r\n" ++
            "*1\r\n$3\r\nGET\r\n" ++
            "*1\r\n$5\r\nHELLO\r\n" ++
            "*2\r\n$6\r\ncLiEnT\r\n$4\r\niNfO\r\n" ++
            "*2\r\n$6\r\nSELECT\r\n$1\r\n0\r\n" ++
            "*2\r\n$5\r\nHELLO\r\n$1\r\n{d}\r\n" ++
            "*2\r\n$6\r\nCLIENT\r\n$4\r\nINFO\r\n" ++
            "*1\r\n$4\r\nPiNg\r\n", .{ version, next_version, next_version });
        defer testing.allocator.free(request);
        var fake_io: TestConnectionIo = .{ .requests = &.{request}, .max_write_bytes = 3 };
        var worker: ClientWorker = undefined;
        initTestWorker(&worker, .fromNanoseconds(100));
        var mock = store.MockStore.init();
        mock.num_databases_result = 2;
        var data_store = mock.store();
        var logger = logging.TestLogger.init();

        serve(fake_io.io(), logger.logger(), worker.stream, &worker.context, &data_store, testing.allocator, 1024, &never_stop_requested);

        var first_buffer: [64]u8 = undefined;
        var second_buffer: [64]u8 = undefined;
        const first_state = try std.fmt.bufPrint(&first_buffer, " db=1 cmd=client|info resp={d} ", .{version});
        const second_state = try std.fmt.bufPrint(&second_buffer, " db=0 cmd=client|info resp={d} ", .{next_version});
        const first = std.mem.indexOf(u8, fake_io.written(), first_state) orelse return error.MissingFirstReport;
        const second = std.mem.indexOf(u8, fake_io.written(), second_state) orelse return error.MissingSecondReport;
        try testing.expect(first < second);
        try testing.expect(std.mem.indexOf(u8, fake_io.written()[first..second], " tot-cmds=7 ") != null);
        try testing.expect(std.mem.indexOf(u8, fake_io.written()[second..], " tot-cmds=10 ") != null);
        try testing.expect(std.mem.indexOf(u8, fake_io.written(), "-ERR unsupported option\r\n-ERR DB index is out of range\r\n-NOPROTO unsupported protocol version\r\n-ERR wrong number of arguments\r\n") != null);
        try testing.expect(std.mem.endsWith(u8, fake_io.written(), "+PONG\r\n"));
        var snapshot = try worker.report.snapshot(testing.allocator);
        defer snapshot.deinit();
        try testing.expectEqual(0, snapshot.values.db_index);
        try testing.expectEqual(next_version, @intFromEnum(snapshot.values.resp));
        try testing.expectEqual(11, snapshot.values.total_cmds);
        try testing.expectEqualStrings("ping", snapshot.values.last_command);
        try testing.expectEqual(request.len, snapshot.values.total_net_in);
        try testing.expectEqual(fake_io.output_len, snapshot.values.total_net_out);
        try testing.expectEqual(0, logger.recordedEvents().len);
        try testing.expectEqual(0, fake_io.close_calls);
    }
}

test "database and protocol publish before success and expected-error output even when writes fail" {
    const testing = std.testing;
    const protocol = @import("../protocol.zig");
    const Worker = struct {
        fn run(fake_io: *TestConnectionIo, logger: logging.Logger, data_store: *store.Store, worker: *ClientWorker) void {
            serve(fake_io.io(), logger, worker.stream, &worker.context, data_store, testing.allocator, 1024, &never_stop_requested);
        }
    };
    const cases = [_]struct {
        request: []const u8,
        reply_prefix: []const u8,
        db_index: u32 = 0,
        resp: protocol.Resp.Version = .resp2,
        command: []const u8,
    }{
        .{ .request = "*2\r\n$6\r\nSELECT\r\n$1\r\n1\r\n", .reply_prefix = "+OK\r\n", .db_index = 1, .command = "select" },
        .{ .request = "*2\r\n$5\r\nHELLO\r\n$1\r\n3\r\n", .reply_prefix = "%7\r\n", .resp = .resp3, .command = "hello" },
        .{ .request = "*1\r\n$5\r\nHELLO\r\n", .reply_prefix = "*14\r\n", .command = "hello" },
        .{ .request = "*2\r\n$6\r\nSELECT\r\n$2\r\n99\r\n", .reply_prefix = "-ERR DB index is out of range\r\n", .command = "select" },
        .{ .request = "*2\r\n$5\r\nHELLO\r\n$1\r\n4\r\n", .reply_prefix = "-NOPROTO unsupported protocol version\r\n", .command = "hello" },
        .{ .request = "*3\r\n$5\r\nHELLO\r\n$1\r\n3\r\n$4\r\nAUTH\r\n", .reply_prefix = "-ERR unsupported option\r\n", .command = "hello" },
    };
    for (cases) |case| {
        for ([_]bool{ false, true }) |fail_write| {
            const request = try std.fmt.allocPrint(testing.allocator, "{s}*1\r\n$4\r\nPING\r\n", .{case.request});
            defer testing.allocator.free(request);
            var fake_io: TestConnectionIo = .{
                .requests = &.{request},
                .max_write_bytes = 2,
                .pause_after_bytes = 0,
                .fail_after_bytes = if (fail_write) 3 else null,
                .write_error = error.ConnectionResetByPeer,
            };
            var connection_worker: ClientWorker = undefined;
            initTestWorker(&connection_worker, .fromNanoseconds(100));
            connection_worker.report.recordDbAndProto(7, .resp3);
            var mock = store.MockStore.init();
            mock.num_databases_result = 2;
            var data_store = mock.store();
            var logger = logging.TestLogger.init();
            const thread = try std.Thread.spawn(.{}, Worker.run, .{ &fake_io, logger.logger(), &data_store, &connection_worker });
            var joined = false;
            defer {
                fake_io.continue_write.set(testing.io);
                if (!joined) thread.join();
            }
            try fake_io.write_paused.waitTimeout(testing.io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });

            try testing.expectEqual(0, fake_io.output_len);
            var tx = connection_worker.report._lock.tryBegin() orelse return error.ReportLockStillHeld;
            tx.end();
            var snapshot = try connection_worker.report.snapshot(testing.allocator);
            defer snapshot.deinit();
            try testing.expectEqual(case.db_index, snapshot.values.db_index);
            try testing.expectEqual(case.resp, snapshot.values.resp);
            try testing.expectEqual(1, snapshot.values.total_cmds);
            try testing.expectEqualStrings(case.command, snapshot.values.last_command);
            try testing.expectEqual(0, snapshot.values.total_net_out);

            fake_io.continue_write.set(testing.io);
            thread.join();
            joined = true;
            if (fail_write) {
                try testing.expectEqualStrings(case.reply_prefix[0..3], fake_io.written());
            } else {
                try testing.expect(std.mem.startsWith(u8, fake_io.written(), case.reply_prefix));
                try testing.expect(std.mem.endsWith(u8, fake_io.written(), "+PONG\r\n"));
            }
            var final_snapshot = try connection_worker.report.snapshot(testing.allocator);
            defer final_snapshot.deinit();
            try testing.expectEqual(case.db_index, final_snapshot.values.db_index);
            try testing.expectEqual(case.resp, final_snapshot.values.resp);
            try testing.expectEqual(@as(u64, if (fail_write) 1 else 2), final_snapshot.values.total_cmds);
            try testing.expectEqualStrings(if (fail_write) case.command else "ping", final_snapshot.values.last_command);
            try testing.expectEqual(fake_io.output_len, final_snapshot.values.total_net_out);
            try testing.expectEqual(0, logger.recordedEvents().len);
            try testing.expectEqual(0, fake_io.close_calls);
        }
    }
}

test "unexpected handler failures count before stopping later pipeline dispatches" {
    const testing = std.testing;
    var fake_io: TestConnectionIo = .{ .requests = &.{"*1\r\n$6\r\ndBsIzE\r\n*1\r\n$4\r\nPING\r\n"} };
    var worker: ClientWorker = undefined;
    initTestWorker(&worker, .fromNanoseconds(100));
    var mock = store.MockStore.init();
    mock.dbsize_result = error.TestStorageSource;
    var data_store = mock.store();
    var logger = logging.TestLogger.init();

    serve(fake_io.io(), logger.logger(), worker.stream, &worker.context, &data_store, testing.allocator, 1024, &never_stop_requested);

    var snapshot = try worker.report.snapshot(testing.allocator);
    defer snapshot.deinit();
    try testing.expectEqual(1, snapshot.values.total_cmds);
    try testing.expectEqualStrings("dbsize", snapshot.values.last_command);
    try testing.expectEqual(1, mock.dbsize_calls);
    try testing.expectEqualStrings("-ERR something went wrong\r\n", fake_io.written());
    try testing.expectEqual(1, logger.recordedEvents().len);
    try testing.expectEqual(error.TestStorageSource, logger.recordedEvents()[0].source.?);
}

test "a Storage source crosses Store and Commander to the connection logger" {
    const testing = std.testing;
    const Storage = @import("../storage/interface.zig");
    const DefaultStorage = @import("../storage/default_storage.zig");
    const PersistenceState = @import("../persistence_state.zig");
    const persistence = @import("../persistence.zig");
    var fake_io: TestConnectionIo = .{ .requests = &.{"*1\r\n$6\r\nDBSIZE\r\n*1\r\n$4\r\nPING\r\n"} };
    var test_logger = logging.TestLogger.init();

    var backend = DefaultStorage.init(testing.io, testing.allocator);
    var fake_storage = backend.storage();
    var fake_vtable = fake_storage.vtable.*;
    fake_vtable.begin = struct {
        fn begin(_: *anyopaque) anyerror!Storage.Tx {
            return error.TestStorageSource;
        }
    }.begin;
    fake_storage.vtable = &fake_vtable;
    var state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });
    var kgc = try persistence.KgcPersistence.init(testing.io, testing.allocator, &state, "scratch-storage-source.kgc");
    var memory_store = store.MemoryStore.init(testing.allocator, &.{fake_storage}, kgc.snapshot(), null);
    var data_store = memory_store.store();
    defer data_store.deinit();

    serve(fake_io.io(), test_logger.logger(), .{ .socket = .{ .handle = 1, .address = undefined } }, &test_connection_context, &data_store, testing.allocator, 1024, &never_stop_requested);

    try testing.expectEqualStrings("-ERR something went wrong\r\n", fake_io.written());
    try testing.expectEqual(0, fake_io.close_calls);
    const events = test_logger.recordedEvents();
    try testing.expectEqual(1, events.len);
    try testing.expectEqual(error.TestStorageSource, events[0].source.?);
}

test "argument count errors use ERR for every command and allow another request" {
    const testing = std.testing;
    const requests = [_][]const u8{
        "*2\r\n$12\r\nBGREWRITEAOF\r\n$1\r\nx\r\n",
        "*3\r\n$6\r\nBGSAVE\r\n$8\r\nSCHEDULE\r\n$1\r\nx\r\n",
        "*2\r\n$6\r\nDBSIZE\r\n$1\r\nx\r\n",
        "*1\r\n$3\r\nDEL\r\n",
        "*1\r\n$4\r\nECHO\r\n",
        "*1\r\n$3\r\nGET\r\n",
        "*3\r\n$4\r\nPING\r\n$1\r\nx\r\n$1\r\ny\r\n",
        "*2\r\n$4\r\nSAVE\r\n$1\r\nx\r\n",
        "*1\r\n$6\r\nSELECT\r\n",
        "*2\r\n$3\r\nSET\r\n$3\r\nkey\r\n",
        "*3\r\n$7\r\nCOMMAND\r\n$5\r\nCOUNT\r\n$1\r\nx\r\n",
        "*1\r\n$6\r\nCLIENT\r\n",
        "*3\r\n$6\r\nCLIENT\r\n$4\r\nINFO\r\n$1\r\nx\r\n",
    };

    for (requests) |request| {
        var fake_io: TestConnectionIo = .{ .requests = &.{ request, "*1\r\n$4\r\nPING\r\n" } };
        var test_logger = logging.TestLogger.init();
        var mock = store.MockStore.init();
        var data_store = mock.store();

        serve(fake_io.io(), test_logger.logger(), .{ .socket = .{ .handle = 1, .address = undefined } }, &test_connection_context, &data_store, testing.allocator, 1024, &never_stop_requested);

        try testing.expectEqualStrings("-ERR wrong number of arguments\r\n+PONG\r\n", fake_io.written());
        try testing.expectEqual(0, test_logger.recordedEvents().len);
    }
}

test "unsupported CLIENT forms use mapped initialization errors and keep the session usable" {
    const testing = std.testing;
    const requests = [_][]const u8{
        "*2\r\n$6\r\nCLIENT\r\n$4\r\nLIST\r\n",
        "*4\r\n$6\r\nCLIENT\r\n$7\r\nSETINFO\r\n$8\r\nLIB-NAME\r\n$4\r\ntest\r\n",
        "*2\r\n$6\r\nCLIENT\r\n$7\r\nUNKNOWN\r\n",
    };
    for (requests) |request| {
        var fake_io: TestConnectionIo = .{ .requests = &.{ request, "*1\r\n$4\r\nPING\r\n" } };
        var test_logger = logging.TestLogger.init();
        var unused_store: store.Store = undefined;
        serve(fake_io.io(), test_logger.logger(), .{ .socket = .{ .handle = 1, .address = undefined } }, &test_connection_context, &unused_store, testing.allocator, 1024, &never_stop_requested);
        try testing.expectEqualStrings("-ERR unsupported option\r\n+PONG\r\n", fake_io.written());
        try testing.expectEqual(0, fake_io.close_calls);
        try testing.expectEqual(0, test_logger.recordedEvents().len);
    }
}

test "commands preserve replies and database state through a connection" {
    const testing = std.testing;
    const DefaultStorage = @import("../storage/default_storage.zig");
    const PersistenceState = @import("../persistence_state.zig");
    const persistence = @import("../persistence.zig");

    var fake_io: TestConnectionIo = .{ .requests = &.{
        "*3\r\n$3\r\nsEt\r\n$3\r\nkey\r\n$5\r\nvalue\r\n",
        "*2\r\n$3\r\nGET\r\n$3\r\nkey\r\n",
        "*2\r\n$3\r\nSET\r\n$3\r\nkey\r\n",
        "*2\r\n$3\r\nGET\r\n$3\r\nkey\r\n",
        "*1\r\n$3\r\nDEL\r\n",
        "*2\r\n$3\r\nGET\r\n$3\r\nkey\r\n",
        "*1\r\n$6\r\nDBSIZE\r\n",
        "*2\r\n$6\r\nSELECT\r\n$1\r\n1\r\n",
        "*2\r\n$3\r\nGET\r\n$3\r\nkey\r\n",
        "*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$5\r\nother\r\n",
        "*1\r\n$6\r\nDBSIZE\r\n",
        "*2\r\n$6\r\nSELECT\r\n$1\r\n0\r\n",
        "*2\r\n$3\r\nDEL\r\n$3\r\nkey\r\n",
        "*2\r\n$3\r\nGET\r\n$3\r\nkey\r\n",
        "*1\r\n$6\r\nDBSIZE\r\n",
    } };
    var test_logger = logging.TestLogger.init();

    var database_zero = DefaultStorage.init(testing.io, testing.allocator);
    var database_one = DefaultStorage.init(testing.io, testing.allocator);
    var persistence_state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });
    var kgc = try persistence.KgcPersistence.init(
        testing.io,
        testing.allocator,
        &persistence_state,
        "command-registry-behavior.kgc",
    );
    var memory_store = store.MemoryStore.init(
        testing.allocator,
        &.{ database_zero.storage(), database_one.storage() },
        kgc.snapshot(),
        null,
    );
    var data_store = memory_store.store();
    defer data_store.deinit();

    serve(
        fake_io.io(),
        test_logger.logger(),
        .{ .socket = .{ .handle = 1, .address = undefined } },
        &test_connection_context,
        &data_store,
        testing.allocator,
        1024,
        &never_stop_requested,
    );

    try testing.expectEqualStrings(
        "+OK\r\n" ++
            "$5\r\nvalue\r\n" ++
            "-ERR wrong number of arguments\r\n" ++
            "$5\r\nvalue\r\n" ++
            "-ERR wrong number of arguments\r\n" ++
            "$5\r\nvalue\r\n" ++
            ":1\r\n" ++
            "+OK\r\n" ++
            "$-1\r\n" ++
            "+OK\r\n" ++
            ":1\r\n" ++
            "+OK\r\n" ++
            ":1\r\n" ++
            "$-1\r\n" ++
            ":0\r\n",
        fake_io.written(),
    );
    try testing.expectEqual(15, fake_io.next_request);
    try testing.expectEqual(0, test_logger.recordedEvents().len);
    try testing.expectEqual(0, fake_io.close_calls);
}

test "a malformed protocol request gets its fixed response without an error event" {
    const testing = std.testing;
    var fake_io: TestConnectionIo = .{ .requests = &.{"?\r\n"} };
    var test_logger = logging.TestLogger.init();
    var mock = store.MockStore.init();
    var data_store = mock.store();

    serve(fake_io.io(), test_logger.logger(), .{ .socket = .{ .handle = 1, .address = undefined } }, &test_connection_context, &data_store, testing.allocator, 1024, &never_stop_requested);

    try testing.expectEqualStrings("-ERR protocol error: invalid RESP type\r\n", fake_io.written());
    try testing.expectEqual(0, fake_io.close_calls);
    try testing.expectEqual(0, test_logger.recordedEvents().len);
}

test "an unknown command gets its fixed response and the connection continues" {
    const testing = std.testing;
    var fake_io: TestConnectionIo = .{ .requests = &.{
        "*1\r\n$7\r\nUNKNOWN\r\n",
        "*1\r\n$4\r\nPING\r\n",
    } };
    var test_logger = logging.TestLogger.init();
    var mock = store.MockStore.init();
    var data_store = mock.store();

    serve(fake_io.io(), test_logger.logger(), .{ .socket = .{ .handle = 1, .address = undefined } }, &test_connection_context, &data_store, testing.allocator, 1024, &never_stop_requested);

    try testing.expectEqualStrings("-ERR unknown command\r\n+PONG\r\n", fake_io.written());
    try testing.expectEqual(2, fake_io.next_request);
    try testing.expectEqual(0, test_logger.recordedEvents().len);
}

test "read failures preserve earlier replies and report only unexpected sources" {
    const testing = std.testing;
    const cases = [_]struct { requests: []const []const u8, reply: []const u8 }{
        .{ .requests = &.{}, .reply = "" },
        .{
            .requests = &.{"*1\r\n$4\r\nPING\r\n*3\r\n$3\r\nSET\r\n$5\r\nfruit\r\n$6\r\nban"},
            .reply = "+PONG\r\n",
        },
    };
    for (cases) |case| {
        for ([_]std.Io.net.Stream.Reader.Error{ error.ConnectionResetByPeer, error.NetworkDown, error.Timeout }) |read_error| {
            var fake_io: TestConnectionIo = .{ .requests = case.requests, .read_error = read_error };
            var test_logger = logging.TestLogger.init();
            var mock = store.MockStore.init();
            var data_store = mock.store();

            serve(fake_io.io(), test_logger.logger(), .{ .socket = .{ .handle = 1, .address = undefined } }, &test_connection_context, &data_store, testing.allocator, 1024, &never_stop_requested);

            try testing.expectEqualStrings(case.reply, fake_io.written());
            try testing.expectEqual(0, mock.set_calls);
            try testing.expectEqual(0, fake_io.close_calls);
            const events = test_logger.recordedEvents();
            try testing.expectEqual(@as(usize, if (read_error == error.ConnectionResetByPeer) 0 else 1), events.len);
            if (events.len > 0) {
                try testing.expectEqual(logging.TestLogger.Event.Kind.err, events[0].kind);
                try testing.expectEqual(read_error, events[0].source.?);
            }
        }
    }
}

test "an unexpected response write source is reported once without closing the borrowed stream" {
    const testing = std.testing;
    for ([_]std.Io.net.Stream.Writer.Error{ error.NetworkDown, error.HostUnreachable }) |write_error| {
        var fake_io: TestConnectionIo = .{ .requests = &.{"*1\r\n$4\r\nPING\r\n"}, .fail_write = true, .write_error = write_error };
        var test_logger = logging.TestLogger.init();
        var mock = store.MockStore.init();
        var data_store = mock.store();

        serve(fake_io.io(), test_logger.logger(), .{ .socket = .{ .handle = 1, .address = undefined } }, &test_connection_context, &data_store, testing.allocator, 1024, &never_stop_requested);

        try testing.expectEqualStrings("", fake_io.written());
        try testing.expectEqual(0, fake_io.close_calls);
        const events = test_logger.recordedEvents();
        try testing.expectEqual(1, events.len);
        try testing.expectEqual(logging.TestLogger.Event.Kind.err, events[0].kind);
        try testing.expectEqual(write_error, events[0].source.?);
    }
}

test "an internal failure reports its source when its error response also fails" {
    const testing = std.testing;
    for ([_]std.Io.net.Stream.Writer.Error{ error.NetworkDown, error.ConnectionResetByPeer, error.SocketUnconnected }) |write_error| {
        var fake_io: TestConnectionIo = .{ .requests = &.{"*1\r\n$6\r\nDBSIZE\r\n"}, .fail_write = true, .write_error = write_error };
        var test_logger = logging.TestLogger.init();
        var mock = store.MockStore.init();
        mock.dbsize_result = error.TestStorageSource;
        var data_store = mock.store();

        serve(fake_io.io(), test_logger.logger(), .{ .socket = .{ .handle = 1, .address = undefined } }, &test_connection_context, &data_store, testing.allocator, 1024, &never_stop_requested);

        try testing.expectEqualStrings("", fake_io.written());
        try testing.expectEqual(0, fake_io.close_calls);
        const events = test_logger.recordedEvents();
        try testing.expectEqual(@as(usize, if (write_error == error.NetworkDown) 2 else 1), events.len);
        try testing.expectEqual(logging.TestLogger.Event.Kind.err, events[0].kind);
        try testing.expectEqual(error.TestStorageSource, events[0].source.?);
        if (write_error == error.NetworkDown) {
            try testing.expectEqual(logging.TestLogger.Event.Kind.err, events[1].kind);
            try testing.expectEqual(write_error, events[1].source.?);
        }
    }
}

test "complete commands in one read advance after replies and mapped errors" {
    const testing = std.testing;
    var fake_io: TestConnectionIo = .{ .requests = &.{
        "*1\r\n$4\r\nPING\r\n" ++
            "*1\r\n$3\r\nGET\r\n" ++
            "*2\r\n$4\r\nECHO\r\n$3\r\n\x00\r\n\r\n" ++
            "*2\r\n$6\r\nSELECT\r\n$1\r\n9\r\n" ++
            "*1\r\n$6\r\nDBSIZE\r\n",
        "*2\r\n$4\r\nECHO\r\n$0\r\n\r\n",
    } };
    var test_logger = logging.TestLogger.init();
    var mock = store.MockStore.init();
    mock.dbsize_result = 7;
    var data_store = mock.store();

    serve(fake_io.io(), test_logger.logger(), .{ .socket = .{ .handle = 1, .address = undefined } }, &test_connection_context, &data_store, testing.allocator, 1024, &never_stop_requested);

    try testing.expectEqualStrings(
        "+PONG\r\n-ERR wrong number of arguments\r\n$3\r\n\x00\r\n\r\n-ERR DB index is out of range\r\n:7\r\n$0\r\n\r\n",
        fake_io.written(),
    );
    try testing.expectEqual(1, mock.dbsize_calls);
    try testing.expectEqual(2, fake_io.next_request);
    try testing.expectEqual(0, test_logger.recordedEvents().len);
}

test "fragmented commands finish at every split and unfinished EOF stays quiet" {
    const testing = std.testing;
    const cases = [_]struct { request: []const u8, reply: []const u8, stored_value: ?[]const u8 = null }{
        .{ .request = "*1\r\n$4\r\nPING\r\n", .reply = "+PONG\r\n" },
        .{ .request = "*2\r\n$4\r\nECHO\r\n$3\r\n\x00\r\n\r\n", .reply = "$3\r\n\x00\r\n\r\n" },
        .{ .request = "*2\r\n$4\r\nECHO\r\n$0\r\n\r\n", .reply = "$0\r\n\r\n" },
        .{ .request = "*3\r\n$3\r\nSET\r\n$0\r\n\r\n$5\r\na\x00\r\nb\r\n", .reply = "+OK\r\n", .stored_value = "a\x00\r\nb" },
    };

    for (cases) |case| {
        for (1..case.request.len) |split| {
            var mock = store.MockStore.init();
            var data_store = mock.store();
            var test_logger = logging.TestLogger.init();
            var fake_io: TestConnectionIo = .{ .requests = &.{ case.request[0..split], case.request[split..], "*1\r\n$4\r\nPING\r\n" } };

            serve(fake_io.io(), test_logger.logger(), .{ .socket = .{ .handle = 1, .address = undefined } }, &test_connection_context, &data_store, testing.allocator, case.request.len, &never_stop_requested);

            var expected_buffer: [64]u8 = undefined;
            const expected = try std.fmt.bufPrint(&expected_buffer, "{s}+PONG\r\n", .{case.reply});
            try testing.expectEqualStrings(expected, fake_io.written());
            if (case.stored_value) |value| {
                try testing.expectEqual(1, mock.set_calls);
                try testing.expectEqualStrings(value, mock.last_set_value_copy[0..mock.last_set_value_len]);
            }
            try testing.expectEqual(0, test_logger.recordedEvents().len);
            try testing.expectEqual(0, fake_io.close_calls);

            var unfinished_mock = store.MockStore.init();
            var unfinished_store = unfinished_mock.store();
            var unfinished_io: TestConnectionIo = .{ .requests = &.{case.request[0..split]} };
            serve(unfinished_io.io(), test_logger.logger(), .{ .socket = .{ .handle = 1, .address = undefined } }, &test_connection_context, &unfinished_store, testing.allocator, case.request.len, &never_stop_requested);

            try testing.expectEqualStrings("", unfinished_io.written());
            try testing.expectEqual(0, unfinished_mock.set_calls);
            try testing.expectEqual(0, test_logger.recordedEvents().len);
            try testing.expectEqual(0, unfinished_io.close_calls);
        }
    }
}

test "unfinished EOF and invalid pipeline tails preserve earlier replies and stored data" {
    const testing = std.testing;
    const DefaultStorage = @import("../storage/default_storage.zig");
    const PersistenceState = @import("../persistence_state.zig");
    const persistence = @import("../persistence.zig");
    const prefix = "*3\r\n$3\r\nSET\r\n$5\r\nfruit\r\n$5\r\napple\r\n" ++
        "*2\r\n$3\r\nGET\r\n$5\r\nfruit\r\n";
    const later_delete = "*2\r\n$3\r\nDEL\r\n$5\r\nfruit\r\n";
    const cases = [_]struct { tail: []const u8, reply: []const u8 = "" }{
        .{ .tail = "*3\r\n$3\r\nSET\r\n$5\r\nfruit\r\n$6\r\nban" },
        .{ .tail = "*3\r\n$3\r\nSET\r\n$5\r\nfruit\r\n$6\r\nbanana\r" },
        .{ .tail = "*3\r\n$3\r\nDEL\r\n$5\r\nfruit\r\n$5\r\nother\r" },
        .{ .tail = "*x\r\n" ++ later_delete, .reply = "-ERR protocol error: malformed request\r\n" },
        .{ .tail = "*3\r\n$3\r\nSET\r\n$5\r\nfruit\r\n$6\r\nbanana\rX" ++ later_delete, .reply = "-ERR protocol error: malformed request\r\n" },
        .{ .tail = "*1025\r\n" ++ later_delete, .reply = "-ERR protocol error: request limit exceeded\r\n" },
        .{ .tail = "*3\r\n$3\r\nSET\r\n$5\r\nfruit\r\n$1048576\r\n", .reply = "-ERR protocol error: request limit exceeded\r\n" },
    };

    for (cases) |case| {
        var request_bytes: [128]u8 = undefined;
        const request = try std.fmt.bufPrint(&request_bytes, "{s}{s}", .{ prefix, case.tail });
        var fake_io: TestConnectionIo = .{ .requests = &.{request} };
        var test_logger = logging.TestLogger.init();
        var backend = DefaultStorage.init(testing.io, testing.allocator);
        var persistence_state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });
        var kgc = try persistence.KgcPersistence.init(testing.io, testing.allocator, &persistence_state, "connection-unfinished-or-malformed-tail.kgc");
        var memory_store = store.MemoryStore.init(testing.allocator, &.{backend.storage()}, kgc.snapshot(), null);
        var data_store = memory_store.store();
        defer data_store.deinit();

        serve(fake_io.io(), test_logger.logger(), .{ .socket = .{ .handle = 1, .address = undefined } }, &test_connection_context, &data_store, testing.allocator, 36, &never_stop_requested);

        var reply_bytes: [64]u8 = undefined;
        const expected = try std.fmt.bufPrint(&reply_bytes, "+OK\r\n$5\r\napple\r\n{s}", .{case.reply});
        try testing.expectEqualStrings(expected, fake_io.written());
        var stored = (try data_store.get("fruit", 0)).?;
        defer stored.deinit();
        try testing.expectEqualStrings("apple", stored.value.string);
        try testing.expectEqual(1, try data_store.dbsize(0));
        try testing.expectEqual(0, test_logger.recordedEvents().len);
        try testing.expectEqual(0, fake_io.close_calls);
    }
}

test "commands larger than initial capacity finish and allow later commands" {
    const testing = std.testing;
    const echo = "*2\r\n$4\r\nECHO\r\n$1\r\nx\r\n";
    const pipeline = "*1\r\n$4\r\nPING\r\n" ++ echo ++ "*1\r\n$6\r\nDBSIZE\r\n";
    const cases = [_]struct { request: []const u8, capacity: usize, reply: []const u8, dbsize_calls: usize = 0 }{
        .{ .request = echo, .capacity = 14, .reply = "$1\r\nx\r\n" },
        .{ .request = pipeline, .capacity = echo.len - 1, .reply = "+PONG\r\n$1\r\nx\r\n:7\r\n", .dbsize_calls = 1 },
        .{ .request = pipeline, .capacity = echo.len, .reply = "+PONG\r\n$1\r\nx\r\n:7\r\n", .dbsize_calls = 1 },
    };

    for (cases) |case| {
        var fake_io: TestConnectionIo = .{ .requests = &.{case.request} };
        var test_logger = logging.TestLogger.init();
        var mock = store.MockStore.init();
        mock.dbsize_result = 7;
        var data_store = mock.store();

        serve(fake_io.io(), test_logger.logger(), .{ .socket = .{ .handle = 1, .address = undefined } }, &test_connection_context, &data_store, testing.allocator, case.capacity, &never_stop_requested);

        try testing.expectEqualStrings(case.reply, fake_io.written());
        try testing.expectEqual(case.dbsize_calls, mock.dbsize_calls);
        try testing.expectEqual(0, test_logger.recordedEvents().len);
        try testing.expectEqual(0, fake_io.close_calls);
    }
}

test "input byte limit accepts an exact frame and rejects a one-byte excess" {
    const testing = std.testing;
    const limit = @import("../protocol.zig").request_decoder.network_limits.max_frame_bytes;
    const prefix = "*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$";
    const overhead = prefix.len + std.fmt.count("{d}", .{limit}) + "\r\n\r\n".len;

    for ([_]usize{ 0, 1 }) |excess| {
        const value_len = limit - overhead + excess;
        const request = try testing.allocator.alloc(u8, limit + excess);
        defer testing.allocator.free(request);
        const header = try std.fmt.bufPrint(request, prefix ++ "{d}\r\n", .{value_len});
        try testing.expectEqual(request.len, header.len + value_len + 2);
        @memset(request[header.len..][0..value_len], 'x');
        @memcpy(request[request.len - 2 ..], "\r\n");
        const pipeline = try std.fmt.allocPrint(testing.allocator, "*1\r\n$4\r\nPING\r\n{s}*1\r\n$6\r\nDBSIZE\r\n", .{request});
        defer testing.allocator.free(pipeline);

        for ([_]usize{ 1024, limit * 2 }) |initial_capacity| {
            var fake_io: TestConnectionIo = .{ .requests = &.{pipeline} };
            var test_logger = logging.TestLogger.init();
            var mock = store.MockStore.init();
            mock.dbsize_result = 7;
            var data_store = mock.store();

            serve(fake_io.io(), test_logger.logger(), .{ .socket = .{ .handle = 1, .address = undefined } }, &test_connection_context, &data_store, testing.allocator, initial_capacity, &never_stop_requested);

            if (excess == 0) {
                try testing.expectEqualStrings("+PONG\r\n+OK\r\n:7\r\n", fake_io.written());
                try testing.expectEqual(1, mock.set_calls);
                try testing.expectEqual(1, mock.dbsize_calls);
            } else {
                try testing.expectEqualStrings("+PONG\r\n-ERR protocol error: request limit exceeded\r\n", fake_io.written());
                try testing.expectEqual(0, mock.set_calls);
                try testing.expectEqual(0, mock.dbsize_calls);
            }
            try testing.expectEqual(0, test_logger.recordedEvents().len);
            try testing.expectEqual(0, fake_io.close_calls);
        }
    }
}

test "element limit counts the command name and prevents oversized mutations" {
    const testing = std.testing;
    const DefaultStorage = @import("../storage/default_storage.zig");
    const PersistenceState = @import("../persistence_state.zig");
    const persistence = @import("../persistence.zig");
    const limit = @import("../protocol.zig").request_decoder.network_limits.max_elements;
    const key_frame = "$5\r\nfruit\r\n";
    const keys = key_frame ** limit;

    for ([_]usize{ 0, 1 }) |excess| {
        const count = limit + excess;
        const request = try std.fmt.allocPrint(testing.allocator, "*3\r\n$3\r\nSET\r\n$5\r\nfruit\r\n$5\r\napple\r\n" ++
            "*{d}\r\n$3\r\nDEL\r\n{s}*1\r\n$4\r\nPING\r\n", .{ count, keys[0 .. (count - 1) * key_frame.len] });
        defer testing.allocator.free(request);
        var fake_io: TestConnectionIo = .{ .requests = &.{request} };
        var test_logger = logging.TestLogger.init();
        var backend = DefaultStorage.init(testing.io, testing.allocator);
        var persistence_state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });
        var kgc = try persistence.KgcPersistence.init(testing.io, testing.allocator, &persistence_state, "connection-element-limit.kgc");
        var memory_store = store.MemoryStore.init(testing.allocator, &.{backend.storage()}, kgc.snapshot(), null);
        var data_store = memory_store.store();
        defer data_store.deinit();

        serve(fake_io.io(), test_logger.logger(), .{ .socket = .{ .handle = 1, .address = undefined } }, &test_connection_context, &data_store, testing.allocator, 128, &never_stop_requested);

        var stored = try data_store.get("fruit", 0);
        defer if (stored) |*value| value.deinit();
        if (excess == 0) {
            try testing.expectEqualStrings("+OK\r\n:1\r\n+PONG\r\n", fake_io.written());
            try testing.expect(stored == null);
            try testing.expectEqual(0, try data_store.dbsize(0));
        } else {
            try testing.expectEqualStrings("+OK\r\n-ERR protocol error: request limit exceeded\r\n", fake_io.written());
            try testing.expect(stored != null);
            try testing.expectEqualStrings("apple", stored.?.value.string);
            try testing.expectEqual(1, try data_store.dbsize(0));
        }
        try testing.expectEqual(0, test_logger.recordedEvents().len);
        try testing.expectEqual(0, fake_io.close_calls);
    }
}

test "growth allocation failure preserves earlier mutations and releases input" {
    const testing = std.testing;
    const DefaultStorage = @import("../storage/default_storage.zig");
    const PersistenceState = @import("../persistence_state.zig");
    const persistence = @import("../persistence.zig");
    const value = "banana" ** 24;
    const request = try std.fmt.allocPrint(testing.allocator, "*3\r\n$3\r\nSET\r\n$5\r\nfruit\r\n$5\r\napple\r\n" ++
        "*3\r\n$3\r\nSET\r\n$5\r\nfruit\r\n${d}\r\n{s}\r\n" ++
        "*2\r\n$3\r\nDEL\r\n$5\r\nfruit\r\n", .{ value.len, value });
    defer testing.allocator.free(request);

    for ([_]bool{ false, true }) |fail_error_reply| {
        var fake_io: TestConnectionIo = .{
            .requests = &.{request},
            .fail_after_bytes = if (fail_error_reply) 5 else null,
        };
        var failing_allocator = testing.FailingAllocator.init(testing.allocator, .{
            .fail_index = 1,
            .resize_fail_index = 0,
        });
        var test_logger = logging.TestLogger.init();
        var backend = DefaultStorage.init(testing.io, testing.allocator);
        var persistence_state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });
        var kgc = try persistence.KgcPersistence.init(testing.io, testing.allocator, &persistence_state, "connection-growth-failure.kgc");
        var memory_store = store.MemoryStore.init(testing.allocator, &.{backend.storage()}, kgc.snapshot(), null);
        var data_store = memory_store.store();
        defer data_store.deinit();

        serve(fake_io.io(), test_logger.logger(), .{ .socket = .{ .handle = 1, .address = undefined } }, &test_connection_context, &data_store, failing_allocator.allocator(), 40, &never_stop_requested);

        const expected = if (fail_error_reply) "+OK\r\n" else "+OK\r\n-ERR something went wrong\r\n";
        try testing.expectEqualStrings(expected, fake_io.written());
        var stored = (try data_store.get("fruit", 0)).?;
        defer stored.deinit();
        try testing.expectEqualStrings("apple", stored.value.string);
        try testing.expectEqual(1, try data_store.dbsize(0));
        const events = test_logger.recordedEvents();
        try testing.expectEqual(@as(usize, if (fail_error_reply) 2 else 1), events.len);
        try testing.expectEqual(error.OutOfMemory, events[0].source.?);
        if (fail_error_reply) try testing.expectEqual(error.NetworkDown, events[1].source.?);
        try testing.expectEqual(0, fake_io.close_calls);
    }
}

test "a growing pipeline tail preserves earlier commands and supports reuse" {
    const testing = std.testing;
    const DefaultStorage = @import("../storage/default_storage.zig");
    const PersistenceState = @import("../persistence_state.zig");
    const persistence = @import("../persistence.zig");
    const large_value = "banana" ** 24;
    const first_request = try std.fmt.allocPrint(testing.allocator, "*1\r\n$4\r\nPING\r\n" ++
        "*3\r\n$3\r\nSET\r\n$5\r\nfruit\r\n$5\r\napple\r\n" ++
        "*2\r\n$3\r\nGET\r\n$5\r\nfruit\r\n" ++
        "*3\r\n$3\r\nSET\r\n$5\r\nfruit\r\n${d}\r\n{s}", .{ large_value.len, large_value[0..17] });
    defer testing.allocator.free(first_request);
    const remainder = try std.fmt.allocPrint(testing.allocator, "{s}\r\n*2\r\n$3\r\nGET\r\n$5\r\nfruit\r\n" ++
        "*3\r\n$3\r\nSET\r\n$5\r\nfruit\r\n$4\r\nplum\r\n" ++
        "*2\r\n$3\r\nGET\r\n$5\r\nfruit\r\n", .{large_value[17..]});
    defer testing.allocator.free(remainder);
    var fake_io: TestConnectionIo = .{ .requests = &.{ first_request, remainder } };
    var test_logger = logging.TestLogger.init();
    var backend = DefaultStorage.init(testing.io, testing.allocator);
    var persistence_state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });
    var kgc = try persistence.KgcPersistence.init(testing.io, testing.allocator, &persistence_state, "connection-retained-tail.kgc");
    var memory_store = store.MemoryStore.init(testing.allocator, &.{backend.storage()}, kgc.snapshot(), null);
    var data_store = memory_store.store();
    defer data_store.deinit();

    serve(fake_io.io(), test_logger.logger(), .{ .socket = .{ .handle = 1, .address = undefined } }, &test_connection_context, &data_store, testing.allocator, 36, &never_stop_requested);

    const expected = try std.fmt.allocPrint(testing.allocator, "+PONG\r\n+OK\r\n$5\r\napple\r\n+OK\r\n${d}\r\n{s}\r\n+OK\r\n$4\r\nplum\r\n", .{ large_value.len, large_value });
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, fake_io.written());
    var stored = (try data_store.get("fruit", 0)).?;
    defer stored.deinit();
    try testing.expectEqualStrings("plum", stored.value.string);
    try testing.expectEqual(0, test_logger.recordedEvents().len);
    try testing.expectEqual(0, fake_io.close_calls);
}

test "pipelined borrowed and owned replies finish through short writes" {
    const testing = std.testing;
    const DefaultStorage = @import("../storage/default_storage.zig");
    const PersistenceState = @import("../persistence_state.zig");
    const persistence = @import("../persistence.zig");
    var fake_io: TestConnectionIo = .{
        .requests = &.{
            "*2\r\n$4\r\nECHO\r\n$3\r\n\x00\r\n\r\n" ++
                "*2\r\n$4\r\nPING\r\n$3\r\n\x00\r\n\r\n" ++
                "*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$3\r\n\x00\r\n\r\n" ++
                "*2\r\n$3\r\nGET\r\n$3\r\nkey\r\n" ++
                "*4\r\n$3\r\nSET\r\n$3\r\nkey\r\n$4\r\nnext\r\n$3\r\nGET\r\n" ++
                "*2\r\n$3\r\nGET\r\n$3\r\nkey\r\n",
            "*2\r\n$4\r\nECHO\r\n$0\r\n\r\n",
        },
        .max_write_bytes = 2,
    };
    var test_logger = logging.TestLogger.init();
    var backend = DefaultStorage.init(testing.io, testing.allocator);
    var persistence_state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });
    var kgc = try persistence.KgcPersistence.init(testing.io, testing.allocator, &persistence_state, "connection-reply-lifetime.kgc");
    var memory_store = store.MemoryStore.init(testing.allocator, &.{backend.storage()}, kgc.snapshot(), null);
    var data_store = memory_store.store();
    defer data_store.deinit();

    serve(fake_io.io(), test_logger.logger(), .{ .socket = .{ .handle = 1, .address = undefined } }, &test_connection_context, &data_store, testing.allocator, 48, &never_stop_requested);

    try testing.expectEqualStrings(
        "$3\r\n\x00\r\n\r\n$3\r\n\x00\r\n\r\n+OK\r\n" ++
            "$3\r\n\x00\r\n\r\n$3\r\n\x00\r\n\r\n$4\r\nnext\r\n$0\r\n\r\n",
        fake_io.written(),
    );
    var stored = (try data_store.get("key", 0)).?;
    defer stored.deinit();
    try testing.expectEqualStrings("next", stored.value.string);
    try testing.expectEqual(0, test_logger.recordedEvents().len);
    try testing.expectEqual(0, fake_io.close_calls);
}

test "invalid later DEL elements prevent mutation and stop the connection" {
    const testing = std.testing;
    const invalid_elements = [_][]const u8{ ":42\r\n", "$-1\r\n", "*0\r\n", "+apple\r\n", "-ERR\r\n" };
    for (invalid_elements) |element| {
        var buffer: [128]u8 = undefined;
        const request = try std.fmt.bufPrint(&buffer, "*3\r\n$3\r\nDEL\r\n$5\r\nfruit\r\n{s}*1\r\n$6\r\nDBSIZE\r\n", .{element});
        var fake_io: TestConnectionIo = .{ .requests = &.{ request, "*1\r\n$4\r\nPING\r\n" } };
        var test_logger = logging.TestLogger.init();
        var mock = store.MockStore.init();
        var data_store = mock.store();

        serve(fake_io.io(), test_logger.logger(), .{ .socket = .{ .handle = 1, .address = undefined } }, &test_connection_context, &data_store, testing.allocator, 1024, &never_stop_requested);

        try testing.expectEqual(0, mock.remove_calls);
        try testing.expectEqual(0, mock.dbsize_calls);
        try testing.expectEqual(1, fake_io.next_request);
        try testing.expect(std.mem.startsWith(u8, fake_io.written(), "-ERR protocol error:"));
        try testing.expectEqual(0, test_logger.recordedEvents().len);
    }
}

test "a blocked reply keeps later mutations pending and permits another storage client" {
    const testing = std.testing;
    const DefaultStorage = @import("../storage/default_storage.zig");
    const PersistenceState = @import("../persistence_state.zig");
    const persistence = @import("../persistence.zig");
    const Worker = struct {
        fn run(fake_io: *TestConnectionIo, logger: logging.Logger, data_store: *store.Store, context: *const ConnectionContext) void {
            serve(fake_io.io(), logger, TestConnectionStream, context, data_store, testing.allocator, 128, &never_stop_requested);
        }

        const TestConnectionStream: std.Io.net.Stream = .{ .socket = .{ .handle = 1, .address = undefined } };
    };
    const Observer = struct {
        data_store: *store.Store,
        done: std.Io.Event = .unset,
        result: anyerror!bool = error.Unexpected,

        fn run(self: *@This()) void {
            defer self.done.set(testing.io);
            self.result = result: {
                var value = (self.data_store.get("fruit", 0) catch |err| break :result err) orelse break :result false;
                defer value.deinit();
                break :result std.mem.eql(u8, value.value.string, "apple");
            };
        }
    };
    const requests = [_][]const u8{
        "*2\r\n$4\r\nECHO\r\n$5\r\napple\r\n",
        "*2\r\n$3\r\nGET\r\n$5\r\nfruit\r\n",
    };
    for (requests) |first_request| {
        const request = try std.fmt.allocPrint(testing.allocator, "{s}*2\r\n$3\r\nDEL\r\n$5\r\nfruit\r\n", .{first_request});
        defer testing.allocator.free(request);
        var fake_io: TestConnectionIo = .{ .requests = &.{request}, .max_write_bytes = 2, .pause_after_bytes = 6 };
        var connection_worker: ClientWorker = undefined;
        initTestWorker(&connection_worker, .fromNanoseconds(100));
        var test_logger = logging.TestLogger.init();
        var backend = DefaultStorage.init(testing.io, testing.allocator);
        var persistence_state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });
        var kgc = try persistence.KgcPersistence.init(testing.io, testing.allocator, &persistence_state, "connection-blocked-reply.kgc");
        var memory_store = store.MemoryStore.init(testing.allocator, &.{backend.storage()}, kgc.snapshot(), null);
        var data_store = memory_store.store();
        defer data_store.deinit();
        _ = try data_store.set(.{ .key = "fruit", .value = "apple", .condition = null, .expires_at = null, .response = null }, 0);

        const worker = try std.Thread.spawn(.{}, Worker.run, .{ &fake_io, test_logger.logger(), &data_store, &connection_worker.context });
        var worker_joined = false;
        defer {
            fake_io.continue_write.set(testing.io);
            if (!worker_joined) worker.join();
        }
        try fake_io.write_paused.waitTimeout(testing.io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
        try testing.expectEqualStrings("$5\r\nap", fake_io.written());
        var report_tx = connection_worker.report._lock.tryBegin() orelse return error.ReportLockStillHeld;
        report_tx.end();
        var report_snapshot = try connection_worker.report.snapshot(testing.allocator);
        defer report_snapshot.deinit();
        try testing.expectEqual(request.len, report_snapshot.values.total_net_in);
        try testing.expectEqual(6, report_snapshot.values.total_net_out);
        try testing.expectEqual(1, report_snapshot.values.total_cmds);
        try testing.expectEqualStrings(if (std.mem.startsWith(u8, first_request, "*2\r\n$4")) "echo" else "get", report_snapshot.values.last_command);

        var observer: Observer = .{ .data_store = &data_store };
        const observer_thread = try std.Thread.spawn(.{}, Observer.run, .{&observer});
        var observer_joined = false;
        defer {
            fake_io.continue_write.set(testing.io);
            if (!observer_joined) observer_thread.join();
        }
        try observer.done.waitTimeout(testing.io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
        observer_thread.join();
        observer_joined = true;
        try testing.expect(try observer.result);

        fake_io.continue_write.set(testing.io);
        worker.join();
        worker_joined = true;
        try testing.expectEqualStrings("$5\r\napple\r\n:1\r\n", fake_io.written());
        var final_snapshot = try connection_worker.report.snapshot(testing.allocator);
        defer final_snapshot.deinit();
        try testing.expectEqual(fake_io.output_len, final_snapshot.values.total_net_out);
        try testing.expectEqual(2, final_snapshot.values.total_cmds);
        try testing.expectEqualStrings("del", final_snapshot.values.last_command);
        try testing.expect((try data_store.get("fruit", 0)) == null);
        try testing.expectEqual(0, test_logger.recordedEvents().len);
        try testing.expectEqual(0, fake_io.close_calls);
    }
}

test "a partial reply failure stops before the next pipelined command and logs only unexpected sources" {
    const testing = std.testing;
    const cases = [_]struct { request: []const u8, expected: []const u8 }{
        .{ .request = "*1\r\n$4\r\nPING\r\n*1\r\n$6\r\nDBSIZE\r\n", .expected = "+PO" },
        .{ .request = "*2\r\n$4\r\nECHO\r\n$5\r\napple\r\n*1\r\n$6\r\nDBSIZE\r\n", .expected = "$5\r\nap" },
        .{ .request = "*3\r\n$7\r\nCOMMAND\r\n$4\r\nINFO\r\n$3\r\nGET\r\n*1\r\n$6\r\nDBSIZE\r\n", .expected = "*1\r" },
    };
    for (cases) |case| {
        for ([_]std.Io.net.Stream.Writer.Error{ error.NetworkDown, error.ConnectionResetByPeer, error.SocketUnconnected }) |write_error| {
            var fake_io: TestConnectionIo = .{
                .requests = &.{case.request},
                .write_error = write_error,
                .fail_after_bytes = case.expected.len,
            };
            var test_logger = logging.TestLogger.init();
            var mock = store.MockStore.init();
            var data_store = mock.store();
            serve(fake_io.io(), test_logger.logger(), .{ .socket = .{ .handle = 1, .address = undefined } }, &test_connection_context, &data_store, testing.allocator, 1024, &never_stop_requested);
            try testing.expectEqualStrings(case.expected, fake_io.written());
            try testing.expectEqual(0, mock.dbsize_calls);
            try testing.expectEqual(0, fake_io.close_calls);
            const events = test_logger.recordedEvents();
            try testing.expectEqual(@as(usize, if (write_error == error.NetworkDown) 1 else 0), events.len);
            if (events.len > 0) {
                try testing.expectEqual(logging.TestLogger.Event.Kind.err, events[0].kind);
                try testing.expectEqual(write_error, events[0].source.?);
            }
        }
    }
}

test "stopping prevents a new command while a live reply finishes" {
    const testing = std.testing;
    const DefaultStorage = @import("../storage/default_storage.zig");
    const PersistenceState = @import("../persistence_state.zig");
    const persistence = @import("../persistence.zig");
    for ([_]enum { read, write }{ .read, .write }) |stop_during| {
        var stop_requested: std.atomic.Value(bool) = .init(false);
        var fake_io: TestConnectionIo = .{
            .requests = &.{"*2\r\n$3\r\nGET\r\n$5\r\nfruit\r\n*3\r\n$3\r\nSET\r\n$5\r\nfruit\r\n$6\r\nbanana\r\n"},
            .max_write_bytes = 2,
            .stop_after_read = if (stop_during == .read) &stop_requested else null,
            .stop_during_write = if (stop_during == .write) &stop_requested else null,
        };
        var worker: ClientWorker = undefined;
        initTestWorker(&worker, .fromNanoseconds(100));
        var test_logger = logging.TestLogger.init();
        var backend = DefaultStorage.init(testing.io, testing.allocator);
        var persistence_state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });
        var kgc = try persistence.KgcPersistence.init(testing.io, testing.allocator, &persistence_state, "connection-stop-between-commands.kgc");
        var memory_store = store.MemoryStore.init(testing.allocator, &.{backend.storage()}, kgc.snapshot(), null);
        var data_store = memory_store.store();
        defer data_store.deinit();
        var initial = try data_store.set(.{ .key = "fruit", .value = "apple", .condition = null, .expires_at = null, .response = null }, 0);
        if (initial.value) |*previous| previous.deinit();

        serve(fake_io.io(), test_logger.logger(), worker.stream, &worker.context, &data_store, testing.allocator, 64, &stop_requested);

        try testing.expect(stop_requested.load(.acquire));
        try testing.expectEqualStrings(if (stop_during == .read) "" else "$5\r\napple\r\n", fake_io.written());
        var stored = (try data_store.get("fruit", 0)).?;
        defer stored.deinit();
        try testing.expectEqualStrings("apple", stored.value.string);
        try testing.expectEqual(0, test_logger.recordedEvents().len);
        try testing.expectEqual(0, fake_io.close_calls);
        var report_snapshot = try worker.report.snapshot(testing.allocator);
        defer report_snapshot.deinit();
        try testing.expectEqual(fake_io.requests[0].len, report_snapshot.values.total_net_in);
        try testing.expectEqual(fake_io.output_len, report_snapshot.values.total_net_out);
        try testing.expectEqual(@as(u64, if (stop_during == .read) 0 else 1), report_snapshot.values.total_cmds);
        try testing.expectEqualStrings(if (stop_during == .read) "NULL" else "get", report_snapshot.values.last_command);
    }
}

test "failed owned replies release their copies and stop later mutations without logging peer disconnects" {
    const testing = std.testing;
    const DefaultStorage = @import("../storage/default_storage.zig");
    const PersistenceState = @import("../persistence_state.zig");
    const persistence = @import("../persistence.zig");
    const cases = [_]struct { request: []const u8, stored_value: []const u8 }{
        .{ .request = "*2\r\n$3\r\nGET\r\n$5\r\nfruit\r\n", .stored_value = "apple" },
        .{ .request = "*4\r\n$3\r\nSET\r\n$5\r\nfruit\r\n$6\r\nbanana\r\n$3\r\nGET\r\n", .stored_value = "banana" },
    };
    for (cases) |case| {
        for ([_]std.Io.net.Stream.Writer.Error{ error.NetworkDown, error.ConnectionResetByPeer, error.SocketUnconnected }) |write_error| {
            var request_bytes: [96]u8 = undefined;
            const request = try std.fmt.bufPrint(&request_bytes, "{s}*2\r\n$3\r\nDEL\r\n$5\r\nfruit\r\n", .{case.request});
            var fake_io: TestConnectionIo = .{ .requests = &.{request}, .write_error = write_error, .fail_after_bytes = 6, .max_write_bytes = 2 };
            var test_logger = logging.TestLogger.init();
            var backend = DefaultStorage.init(testing.io, testing.allocator);
            var persistence_state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });
            var kgc = try persistence.KgcPersistence.init(testing.io, testing.allocator, &persistence_state, "connection-failed-owned-replies.kgc");
            var memory_store = store.MemoryStore.init(testing.allocator, &.{backend.storage()}, kgc.snapshot(), null);
            var data_store = memory_store.store();
            defer data_store.deinit();
            var initial = try data_store.set(.{ .key = "fruit", .value = "apple", .condition = null, .expires_at = null, .response = null }, 0);
            if (initial.value) |*previous| previous.deinit();

            serve(fake_io.io(), test_logger.logger(), .{ .socket = .{ .handle = 1, .address = undefined } }, &test_connection_context, &data_store, testing.allocator, 80, &never_stop_requested);

            try testing.expectEqualStrings("$5\r\nap", fake_io.written());
            var stored = (try data_store.get("fruit", 0)).?;
            defer stored.deinit();
            try testing.expectEqualStrings(case.stored_value, stored.value.string);
            try testing.expectEqual(0, fake_io.close_calls);
            const events = test_logger.recordedEvents();
            try testing.expectEqual(@as(usize, if (write_error == error.NetworkDown) 1 else 0), events.len);
            if (events.len > 0) {
                try testing.expectEqual(logging.TestLogger.Event.Kind.err, events[0].kind);
                try testing.expectEqual(write_error, events[0].source.?);
            }
        }
    }
}
