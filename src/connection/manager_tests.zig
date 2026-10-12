const std = @import("std");
const logging = @import("../logger.zig");
const store = @import("../store.zig");
const TestNetwork = @import("test_network.zig");
const ConnectionManager = @import("../connection.zig").ConnectionManager;
const ClientWorker = ConnectionManager.ClientWorker;
const socket_metadata = @import("socket_metadata.zig");

test "live snapshots own identity and reports across label replacement and manager destruction" {
    const testing = std.testing;
    const Context = @import("context.zig");
    var network = TestNetwork.init(testing.io, 2);
    network.registration_time = .fromNanoseconds(100);
    var snapshots: Context.LiveSnapshots = captured: {
        var mock = store.MockStore.init();
        var data_store = mock.store();
        var manager = ConnectionManager.initWithOptions(network.io(), testing.allocator, logging.NoopLogger.logger(), &data_store, 1024, .{ .local_endpoint = TestNetwork.localEndpoint });
        defer manager.deinit() catch unreachable;
        try manager.start(TestNetwork.stream(7));
        try manager.start(TestNetwork.stream(8));
        network.all_reads_started.waitUncancelable(testing.io);
        const first = manager._workers.items[0];
        const second = manager._workers.items[1];
        first.context.recordDbAndProto(2, .resp3);
        first.context.recordDispatch("client|list");
        try first.context.setLibraryInfo(.lib_name, "First");
        try second.context.setLibraryInfo(.lib_name, "Second");
        try second.context.setLibraryInfo(.lib_ver, "V2");
        var owned = try first.context.snapshotLive(manager._io, testing.allocator);
        errdefer owned.deinit();
        try testing.expectEqual(2, owned.items.len);
        var tx = manager._lock.tryBegin() orelse return error.ManagerLockStillHeld;
        tx.end();
        for (manager._workers.items) |worker| {
            tx = worker.report._lock.tryBegin() orelse return error.ReportLockStillHeld;
            tx.end();
        }
        try first.context.setLibraryInfo(.lib_name, "Replaced");
        try second.context.setLibraryInfo(.lib_name, "");
        break :captured owned;
    };
    defer snapshots.deinit();
    const first = snapshots.items[0];
    const second = snapshots.items[1];
    try testing.expectEqual(1, first.id);
    try testing.expectEqual(2, second.id);
    const first_peer: std.Io.net.IpAddress = .{ .ip4 = .loopback(10007) };
    const second_peer: std.Io.net.IpAddress = .{ .ip4 = .loopback(10008) };
    try testing.expect(first.peer_endpoint.eql(&first_peer));
    try testing.expect(second.peer_endpoint.eql(&second_peer));
    try testing.expect(first.local_endpoint.eql(&network.local_endpoint_value));
    try testing.expectEqual(7, first.descriptor);
    try testing.expectEqual(std.Io.Timestamp.fromNanoseconds(100), first.registered_at);
    try testing.expectEqual(std.Io.Timestamp.fromNanoseconds(100), first.sampled_at);
    try testing.expectEqual(2, first.report.values.db_index);
    try testing.expectEqual(@import("../protocol.zig").Resp.Version.resp3, first.report.values.resp);
    try testing.expectEqualStrings("client|list", first.report.values.last_command);
    try testing.expectEqual(1, first.report.values.total_cmds);
    try testing.expectEqualStrings("First", first.report.values.lib_name);
    try testing.expectEqualStrings("Second", second.report.values.lib_name);
    try testing.expectEqualStrings("V2", second.report.values.lib_ver);
    try testing.expectEqual(2, network.close_calls.load(.acquire));
}

test "live snapshots exclude finished records before and after reaping" {
    const testing = std.testing;
    var network = TestNetwork.init(testing.io, 1);
    network.immediate_eof_handle = 7;
    var mock = store.MockStore.init();
    var data_store = mock.store();
    var manager = ConnectionManager.initWithOptions(network.io(), testing.allocator, logging.NoopLogger.logger(), &data_store, 1024, .{ .local_endpoint = TestNetwork.localEndpoint });
    defer manager.deinit() catch unreachable;
    try manager.start(TestNetwork.stream(7));
    try manager.start(TestNetwork.stream(8));
    network.immediate_closed.waitUncancelable(testing.io);
    network.all_reads_started.waitUncancelable(testing.io);
    const caller = manager._workers.items[1];
    var before = try caller.context.snapshotLive(manager._io, testing.allocator);
    defer before.deinit();
    try testing.expectEqual(1, before.items.len);
    try testing.expectEqual(2, before.items[0].id);
    try testing.expectEqual(2, manager._workers.items.len);
    try manager.reapFinished();
    var after = try caller.context.snapshotLive(manager._io, testing.allocator);
    defer after.deinit();
    try testing.expectEqual(1, after.items.len);
    try testing.expectEqual(2, after.items[0].id);
    try testing.expectEqual(1, manager._workers.items.len);
}

test "live snapshots release partial rows and all locks on every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, liveAllocation, .{});
}

fn liveAllocation(allocator: std.mem.Allocator) !void {
    const testing = std.testing;
    var network = TestNetwork.init(testing.io, 2);
    var mock = store.MockStore.init();
    var data_store = mock.store();
    var manager = ConnectionManager.initWithOptions(network.io(), testing.allocator, logging.NoopLogger.logger(), &data_store, 1024, .{ .local_endpoint = TestNetwork.localEndpoint });
    defer manager.deinit() catch unreachable;
    try manager.start(TestNetwork.stream(7));
    try manager.start(TestNetwork.stream(8));
    network.all_reads_started.waitUncancelable(testing.io);
    try manager._workers.items[0].context.setLibraryInfo(.lib_name, "First");
    try manager._workers.items[1].context.setLibraryInfo(.lib_name, "Second");
    defer {
        var tx = manager._lock.tryBegin() orelse unreachable;
        tx.end();
        for (manager._workers.items) |worker| {
            tx = worker.report._lock.tryBegin() orelse unreachable;
            tx.end();
        }
    }
    var snapshots = try manager._workers.items[0].context.snapshotLive(manager._io, allocator);
    defer snapshots.deinit();
    try testing.expectEqual(2, snapshots.items.len);
}

test "live snapshot copies remain coherent while labels and manager membership change" {
    const testing = std.testing;
    const Churn = struct {
        manager: *ConnectionManager,
        caller: *ClientWorker,
        done: std.atomic.Value(bool) = .init(false),
        failure: ?anyerror = null,

        fn run(self: *@This()) void {
            defer self.done.store(true, .release);
            for (0..32) |index| {
                self.caller.context.recordDbAndProto(if (index % 2 == 0) 7 else 8, if (index % 2 == 0) .resp3 else .resp2);
                self.caller.context.setLibraryInfo(.lib_name, if (index % 2 == 0) "A" else "LongerLibrary") catch |err| {
                    self.failure = err;
                    return;
                };
                self.manager.start(TestNetwork.stream(7)) catch |err| {
                    self.failure = err;
                    return;
                };
                self.manager.reapFinished() catch |err| {
                    self.failure = err;
                    return;
                };
            }
        }
    };
    var network = TestNetwork.init(testing.io, 1);
    network.immediate_eof_handle = 7;
    var mock = store.MockStore.init();
    var data_store = mock.store();
    var manager = ConnectionManager.initWithOptions(network.io(), testing.allocator, logging.NoopLogger.logger(), &data_store, 1024, .{ .local_endpoint = TestNetwork.localEndpoint });
    defer manager.deinit() catch unreachable;
    try manager.start(TestNetwork.stream(8));
    network.all_reads_started.waitUncancelable(testing.io);
    const caller = manager._workers.items[0];
    var churn: Churn = .{ .manager = &manager, .caller = caller };
    const thread = try std.Thread.spawn(.{}, Churn.run, .{&churn});
    var joined = false;
    defer if (!joined) thread.join();
    var captures: usize = 0;
    while (!churn.done.load(.acquire) or captures < 32) : (captures += 1) {
        var snapshots = try caller.context.snapshotLive(manager._io, testing.allocator);
        defer snapshots.deinit();
        try testing.expect(snapshots.items.len >= 1);
        for (snapshots.items) |snapshot| {
            if (snapshot.id != 1) continue;
            const values = snapshot.report.values;
            try testing.expect((values.db_index == 0 and values.resp == .resp2) or
                (values.db_index == 7 and values.resp == .resp3) or
                (values.db_index == 8 and values.resp == .resp2));
            try testing.expect(std.mem.eql(u8, values.lib_name, "") or
                std.mem.eql(u8, values.lib_name, "A") or
                std.mem.eql(u8, values.lib_name, "LongerLibrary"));
        }
    }
    thread.join();
    joined = true;
    if (churn.failure) |err| return err;
}

test "connection manager boundary compiles" {
    std.testing.refAllDecls(ConnectionManager);
    std.testing.refAllDecls(ClientWorker);
}

test "a blocked CLIENT LIST writer releases collection and report locks and joins during shutdown" {
    const testing = std.testing;
    const Shutdown = struct {
        manager: *ConnectionManager,
        done: std.Io.Event = .unset,
        result: anyerror!void = error.Unexpected,

        fn run(self: *@This()) void {
            self.result = self.manager.deinit();
            self.done.set(testing.io);
        }
    };
    var mock = store.MockStore.init();
    var data_store = mock.store();
    var logger = logging.TestLogger.init();
    var manager = ConnectionManager.init(testing.io, testing.allocator, logger.logger(), &data_store, 128);
    var stopped = false;
    defer if (!stopped) manager.deinit() catch {};
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var listener = try address.listen(testing.io, .{ .reuse_address = true });
    defer listener.deinit(testing.io);
    const slow = try listener.socket.address.connect(testing.io, .{ .mode = .stream });
    var slow_open = true;
    defer if (slow_open) slow.close(testing.io);
    const capacity: c_int = 4096;
    try std.posix.setsockopt(slow.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVBUF, std.mem.asBytes(&capacity));
    const accepted = try listener.accept(testing.io);
    std.posix.setsockopt(accepted.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDBUF, std.mem.asBytes(&capacity)) catch |err| {
        accepted.close(testing.io);
        return err;
    };
    try manager.start(accepted);
    const caller = manager._workers.items[0];
    const label = try testing.allocator.alloc(u8, 512 * 1024);
    defer testing.allocator.free(label);
    @memset(label, 'x');
    try caller.context.setLibraryInfo(.lib_name, label);
    try caller.context.setLibraryInfo(.lib_ver, label);

    var writer = slow.writer(testing.io, &.{});
    try writer.interface.writeAll("*2\r\n$6\r\nCLIENT\r\n$4\r\nLIST\r\n*1\r\n$4\r\nPING\r\n");
    try writer.interface.flush();
    const deadline: std.Io.Timeout = .{ .deadline = .fromNow(testing.io, .{ .raw = .fromSeconds(3), .clock = .awake }) };
    var header: [32]u8 = undefined;
    var header_len: usize = 0;
    while (header_len < header.len) {
        const message = try slow.socket.receiveTimeout(testing.io, header[header_len..][0..1], deadline);
        if (message.data.len == 0) return error.PrematureReplyEnd;
        header_len += 1;
        if (header[header_len - 1] == '\n') break;
    }
    try testing.expect(header_len >= 4 and header[0] == '$');
    const length = try std.fmt.parseInt(usize, header[1 .. header_len - 2], 10);
    try testing.expect(length > 2 * label.len);

    var tx = manager._lock.tryBegin() orelse return error.ManagerLockStillHeld;
    tx.end();
    const report_deadline = std.Io.Clock.awake.now(testing.io).nanoseconds + 100 * std.time.ns_per_ms;
    while (true) {
        var report_tx = caller.report._lock.tryBegin() orelse {
            if (std.Io.Clock.awake.now(testing.io).nanoseconds >= report_deadline) return error.ReportLockStillHeld;
            try std.Io.sleep(testing.io, .fromMilliseconds(1), .awake);
            continue;
        };
        const before = caller.report._values;
        report_tx.end();
        try testing.expectEqual(1, before.total_cmds);
        try testing.expectEqualStrings("client|list", before.last_command);
        break;
    }

    const observer = try listener.socket.address.connect(testing.io, .{ .mode = .stream });
    defer observer.close(testing.io);
    try manager.start(try listener.accept(testing.io));
    var observer_writer = observer.writer(testing.io, &.{});
    try observer_writer.interface.writeAll("*1\r\n$4\r\nPING\r\n");
    try observer_writer.interface.flush();
    var pong: [7]u8 = undefined;
    var received: usize = 0;
    while (received < pong.len) {
        const message = try observer.socket.receiveTimeout(testing.io, pong[received..], deadline);
        if (message.data.len == 0) return error.PrematureReplyEnd;
        received += message.data.len;
    }
    try testing.expectEqualStrings("+PONG\r\n", &pong);

    var shutdown: Shutdown = .{ .manager = &manager };
    const thread = try std.Thread.spawn(.{}, Shutdown.run, .{&shutdown});
    const in_time = finished: {
        shutdown.done.waitTimeout(testing.io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } }) catch {
            slow.close(testing.io);
            slow_open = false;
            break :finished false;
        };
        break :finished true;
    };
    thread.join();
    stopped = true;
    try testing.expect(in_time);
    try shutdown.result;
    try testing.expectEqual(0, logger.recordedEvents().len);
}

test "connection IDs and borrowed contexts stay stable as the collection grows" {
    const testing = std.testing;
    const worker_count = 16;
    var network = TestNetwork.init(testing.io, worker_count);
    var mock = store.MockStore.init();
    var data_store = mock.store();
    var manager = ConnectionManager.initWithOptions(network.io(), testing.allocator, logging.NoopLogger.logger(), &data_store, 1024, .{ .local_endpoint = TestNetwork.localEndpoint });
    defer manager.deinit() catch unreachable;

    try manager.start(TestNetwork.stream(1));
    const first_context = &manager._workers.items[0].context;
    const first_report = &manager._workers.items[0].report;
    for (2..worker_count + 1) |handle| {
        try manager.start(TestNetwork.stream(handle));
    }
    network.all_reads_started.waitUncancelable(testing.io);

    var lock_tx = try manager._lock.begin();
    defer lock_tx.end();
    try testing.expect(&manager._workers.items[0].context == first_context);
    try testing.expect(&manager._workers.items[0].report == first_report);
    for (manager._workers.items, 1..) |worker, expected_id| {
        try testing.expectEqual(@as(u64, expected_id), worker.context.id);
        try testing.expect(worker.context.ptr == @as(*anyopaque, worker));
        var snapshot = try worker.context.snapshotCurrent(manager._io, testing.allocator);
        defer snapshot.deinit();
        try testing.expectEqual(worker.context.id, snapshot.id);
        try testing.expect(worker.peer_endpoint.eql(&snapshot.peer_endpoint));
        try testing.expect(worker.local_endpoint.eql(&snapshot.local_endpoint));
        try testing.expectEqual(worker.descriptor, snapshot.descriptor);
    }
}

test "current snapshots use request storage and survive manager destruction" {
    const testing = std.testing;
    var network = TestNetwork.init(testing.io, 1);
    network.registration_time = .fromNanoseconds(100);
    const io = network.io();
    var request_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer request_arena.deinit();

    var snapshot = captured: {
        var mock = store.MockStore.init();
        var data_store = mock.store();
        var manager = ConnectionManager.initWithOptions(io, testing.allocator, logging.NoopLogger.logger(), &data_store, 1024, .{ .local_endpoint = TestNetwork.localEndpoint });
        defer manager.deinit() catch unreachable;
        try manager.start(TestNetwork.stream(7));
        network.all_reads_started.waitUncancelable(testing.io);
        const worker = manager._workers.items[0];
        worker.report.recordDbAndProto(2, .resp3);
        worker.report.recordRead(12, .fromNanoseconds(200));
        worker.report.recordWrite(34, .fromNanoseconds(300));
        worker.report.recordDispatch("client|info");
        try worker.context.setLibraryInfo(.lib_name, "test-library");
        try worker.context.setLibraryInfo(.lib_ver, "1.2.3");
        network.registration_time = .fromNanoseconds(500);
        const state = @import("client_state.zig").initWithConnection(&worker.context);
        var owned = try state.connection_context.?.snapshotCurrent(io, request_arena.allocator());
        errdefer owned.deinit();
        var tx = worker.report._lock.tryBegin() orelse return error.ReportLockStillHeld;
        tx.end();
        break :captured owned;
    };
    defer snapshot.deinit();

    try testing.expectEqual(1, snapshot.id);
    const peer: std.Io.net.IpAddress = .{ .ip4 = .loopback(10007) };
    try testing.expect(snapshot.peer_endpoint.eql(&peer));
    try testing.expect(snapshot.local_endpoint.eql(&network.local_endpoint_value));
    try testing.expectEqual(7, snapshot.descriptor);
    try testing.expectEqual(std.Io.Timestamp.fromNanoseconds(100), snapshot.registered_at);
    try testing.expectEqual(std.Io.Timestamp.fromNanoseconds(500), snapshot.sampled_at);
    try testing.expectEqual(2, network.awake_samples.load(.acquire));
    try testing.expectEqual(2, snapshot.report.values.db_index);
    try testing.expectEqual(@import("../protocol.zig").Resp.Version.resp3, snapshot.report.values.resp);
    try testing.expectEqualStrings("client|info", snapshot.report.values.last_command);
    try testing.expectEqualStrings("test-library", snapshot.report.values.lib_name);
    try testing.expectEqualStrings("1.2.3", snapshot.report.values.lib_ver);
    try testing.expectEqual(12, snapshot.report.values.total_net_in);
    try testing.expectEqual(34, snapshot.report.values.total_net_out);
    try testing.expectEqual(1, snapshot.report.values.total_cmds);
    try testing.expectEqual(std.Io.Timestamp.fromNanoseconds(300), snapshot.report.values.last_activity);
    try testing.expectEqual(1, network.close_calls.load(.acquire));
    try testing.expectEqual(1, network.shutdown_calls.load(.acquire));
}

test "owned labels are freed during repeated reaping and shutdown" {
    const testing = std.testing;
    var network = TestNetwork.init(testing.io, 1);
    network.immediate_eof_handle = 7;
    var mock = store.MockStore.init();
    var data_store = mock.store();
    var manager = ConnectionManager.initWithOptions(network.io(), testing.allocator, logging.NoopLogger.logger(), &data_store, 1024, .{ .local_endpoint = TestNetwork.localEndpoint });
    defer manager.deinit() catch unreachable;
    try manager.start(TestNetwork.stream(7));
    const first = manager._workers.items[0];
    try first.context.setLibraryInfo(.lib_name, "First");
    try first.context.setLibraryInfo(.lib_name, "Replacement");
    try first.context.setLibraryInfo(.lib_ver, "V1");
    var snapshot = try first.context.snapshotCurrent(manager._io, testing.allocator);
    defer snapshot.deinit();
    network.immediate_closed.waitUncancelable(testing.io);
    try manager.reapFinished();
    try manager.reapFinished();
    try testing.expectEqual(0, manager._workers.items.len);
    try testing.expectEqualStrings("Replacement", snapshot.report.values.lib_name);
    try testing.expectEqualStrings("V1", snapshot.report.values.lib_ver);
    try manager.start(TestNetwork.stream(8));
    const second = manager._workers.items[0];
    try second.context.setLibraryInfo(.lib_name, "Second");
    try second.context.setLibraryInfo(.lib_ver, "V2");
    network.all_reads_started.waitUncancelable(testing.io);
    try manager.deinit();
    try testing.expectEqual(2, network.close_calls.load(.acquire));
    try testing.expectEqual(1, network.shutdown_calls.load(.acquire));
}

test "worker registration captures endpoint metadata and one monotonic time sample" {
    const testing = std.testing;
    const cases = [_]struct { peer: std.Io.net.IpAddress, local: std.Io.net.IpAddress }{
        .{ .peer = try .parseIp4("192.0.2.10", 40000), .local = try .parseIp4("192.0.2.20", 6379) },
        .{ .peer = try .parseIp6("2001:db8::10", 40001), .local = try .parseIp6("2001:db8::20", 6380) },
    };
    for (cases) |case| {
        var network = TestNetwork.init(testing.io, 1);
        network.registration_time = .fromNanoseconds(12345678901);
        network.local_endpoint_value = case.local;
        var mock = store.MockStore.init();
        var data_store = mock.store();
        var manager = ConnectionManager.initWithOptions(network.io(), testing.allocator, logging.NoopLogger.logger(), &data_store, 1024, .{ .local_endpoint = TestNetwork.localEndpoint });
        defer manager.deinit() catch unreachable;

        var stream = TestNetwork.stream(7);
        stream.socket.address = case.peer;
        try manager.start(stream);
        network.all_reads_started.waitUncancelable(testing.io);

        var manager_tx = try manager._lock.begin();
        defer manager_tx.end();
        const worker = manager._workers.items[0];
        try testing.expect(worker.peer_endpoint.eql(&case.peer));
        try testing.expect(worker.local_endpoint.eql(&case.local));
        try testing.expectEqual(stream.socket.handle, worker.descriptor);
        try testing.expectEqual(network.registration_time.?, worker.registered_at);
        try testing.expectEqual(1, network.awake_samples.load(.acquire));
        try testing.expectEqual(1, network.local_endpoint_calls);
        try testing.expectEqual(stream.socket.handle, network.last_local_endpoint_handle.?);

        var report_tx = try worker.report._lock.begin();
        defer report_tx.end();
        const values = worker.report._values;
        try testing.expectEqual(worker.registered_at, values.last_activity);
        try testing.expectEqual(0, values.db_index);
        try testing.expectEqual(@import("../protocol.zig").Resp.Version.resp2, values.resp);
        try testing.expectEqualStrings("NULL", values.last_command);
        try testing.expectEqualStrings("", values.lib_name);
        try testing.expectEqualStrings("", values.lib_ver);
        try testing.expectEqual(0, values.total_net_in);
        try testing.expectEqual(0, values.total_net_out);
        try testing.expectEqual(0, values.total_cmds);
    }
}

test "accepted sockets report actual local endpoints from wildcard listeners" {
    const testing = std.testing;
    const cases = [_]struct { wildcard: std.Io.net.IpAddress, loopback: std.Io.net.IpAddress }{
        .{ .wildcard = .{ .ip4 = .unspecified(0) }, .loopback = .{ .ip4 = .loopback(0) } },
        .{ .wildcard = .{ .ip6 = .unspecified(0) }, .loopback = .{ .ip6 = .loopback(0) } },
    };
    for (cases) |case| {
        var listener = try case.wildcard.listen(testing.io, .{ .reuse_address = true });
        defer listener.deinit(testing.io);
        var target = case.loopback;
        target.setPort(listener.socket.address.getPort());
        const client = try target.connect(testing.io, .{ .mode = .stream });
        defer client.close(testing.io);
        const peer = try socket_metadata.localEndpoint(testing.io, client.socket.handle);
        const accepted = try listener.accept(testing.io);

        var mock = store.MockStore.init();
        var data_store = mock.store();
        var manager = ConnectionManager.init(testing.io, testing.allocator, logging.NoopLogger.logger(), &data_store, 1024);
        defer manager.deinit() catch unreachable;
        const before = std.Io.Clock.awake.now(testing.io);
        try manager.start(accepted);
        const after = std.Io.Clock.awake.now(testing.io);

        var manager_tx = try manager._lock.begin();
        defer manager_tx.end();
        const worker = manager._workers.items[0];
        try testing.expect(worker.peer_endpoint.eql(&peer));
        try testing.expect(worker.local_endpoint.eql(&target));
        try testing.expect(!worker.local_endpoint.eql(&listener.socket.address));
        try testing.expectEqual(accepted.socket.handle, worker.descriptor);
        try testing.expect(worker.registered_at.nanoseconds >= before.nanoseconds);
        try testing.expect(worker.registered_at.nanoseconds <= after.nanoseconds);
    }
}

test "metadata failure frees the unpublished record and closes the consumed stream once" {
    const testing = std.testing;
    var network = TestNetwork.init(testing.io, 1);
    network.local_endpoint_error = error.TestEndpointFailure;
    var mock = store.MockStore.init();
    var data_store = mock.store();
    var manager = ConnectionManager.initWithOptions(network.io(), testing.allocator, logging.NoopLogger.logger(), &data_store, 1024, .{ .local_endpoint = TestNetwork.localEndpoint });
    errdefer manager.deinit() catch {};

    try testing.expectError(error.TestEndpointFailure, manager.start(TestNetwork.stream(1)));
    try testing.expectEqual(0, manager._workers.items.len);
    try testing.expectEqual(1, network.close_calls.load(.acquire));
    try testing.expectEqual(0, network.blocked_reads.load(.acquire));
    try testing.expectEqual(0, network.awake_samples.load(.acquire));

    network.local_endpoint_error = null;
    try manager.start(TestNetwork.stream(2));
    network.all_reads_started.waitUncancelable(testing.io);
    try testing.expectEqual(1, manager._workers.items.len);
    try testing.expectEqual(@as(u64, 1), manager._workers.items[0].context.id);
    try testing.expectEqual(2, network.local_endpoint_calls);
    try manager.deinit();
    try testing.expectEqual(2, network.close_calls.load(.acquire));
    try testing.expectEqual(1, network.shutdown_calls.load(.acquire));
}

test "native local endpoint lookup errors use the existing start failure cleanup" {
    const testing = std.testing;
    var network = TestNetwork.init(testing.io, 0);
    var mock = store.MockStore.init();
    var data_store = mock.store();
    var manager = ConnectionManager.init(network.io(), testing.allocator, logging.NoopLogger.logger(), &data_store, 1024);
    errdefer manager.deinit() catch {};
    const stream: std.Io.net.Stream = .{ .socket = .{ .handle = -1, .address = .{ .ip4 = .loopback(40000) } } };

    try testing.expectError(error.BadFileDescriptor, manager.start(stream));
    try testing.expectEqual(0, manager._workers.items.len);
    try testing.expectEqual(1, network.close_calls.load(.acquire));
    try manager.deinit();
    try testing.expectEqual(1, network.close_calls.load(.acquire));
    try testing.expectEqual(0, network.shutdown_calls.load(.acquire));
}

test "connection IDs are never reused after finished workers are reaped" {
    const testing = std.testing;
    var network = TestNetwork.init(testing.io, 0);
    network.immediate_eof_handle = 1;
    var mock = store.MockStore.init();
    var data_store = mock.store();
    var manager = ConnectionManager.initWithOptions(network.io(), testing.allocator, logging.NoopLogger.logger(), &data_store, 1024, .{ .local_endpoint = TestNetwork.localEndpoint });
    defer manager.deinit() catch unreachable;

    for (1..4) |expected_id| {
        network.immediate_closed.reset();
        try manager.start(TestNetwork.stream(1));
        network.immediate_closed.waitUncancelable(testing.io);
        {
            var lock_tx = try manager._lock.begin();
            defer lock_tx.end();
            try testing.expectEqual(@as(u64, expected_id), manager._workers.items[0].context.id);
        }
        try manager.reapFinished();
        try testing.expectEqual(0, manager._workers.items.len);
        try testing.expectEqual(expected_id, network.close_calls.load(.acquire));
    }
}

test "deinit wakes an idle worker and closes its stream once" {
    const testing = std.testing;
    var network = TestNetwork.init(testing.io, 1);
    var mock = store.MockStore.init();
    var data_store = mock.store();
    var manager = ConnectionManager.initWithOptions(
        network.io(),
        testing.allocator,
        logging.NoopLogger.logger(),
        &data_store,
        1024,
        .{ .local_endpoint = TestNetwork.localEndpoint },
    );
    errdefer manager.deinit() catch {};

    try manager.start(TestNetwork.stream(1));
    network.all_reads_started.waitUncancelable(testing.io);
    try manager.deinit();
    try manager.deinit();

    try testing.expectEqual(1, network.shutdown_calls.load(.acquire));
    try testing.expectEqual(1, network.close_calls.load(.acquire));
}

test "deinit wakes every idle worker before any worker closes" {
    const testing = std.testing;
    const worker_count = 4;
    var network = TestNetwork.init(testing.io, worker_count);
    var mock = store.MockStore.init();
    var data_store = mock.store();
    var manager = ConnectionManager.initWithOptions(
        network.io(),
        testing.allocator,
        logging.NoopLogger.logger(),
        &data_store,
        1024,
        .{ .local_endpoint = TestNetwork.localEndpoint },
    );
    errdefer manager.deinit() catch {};

    for (1..worker_count + 1) |handle| {
        try manager.start(TestNetwork.stream(handle));
    }
    network.all_reads_started.waitUncancelable(testing.io);
    try manager.deinit();

    try testing.expectEqual(worker_count, network.shutdown_calls.load(.acquire));
    try testing.expectEqual(worker_count, network.close_calls.load(.acquire));
    try testing.expect(!network.close_before_all_shutdown.load(.acquire));
}

test "deinit wakes a real blocked writer and idle reader before joining" {
    const testing = std.testing;
    const DefaultStorage = @import("../storage/default_storage.zig");
    const PersistenceState = @import("../persistence_state.zig");
    const persistence = @import("../persistence.zig");
    const Shutdown = struct {
        manager: *ConnectionManager,
        done: std.Io.Event = .unset,
        result: anyerror!void = error.Unexpected,

        fn run(self: *@This()) void {
            self.result = self.manager.deinit();
            self.done.set(testing.io);
        }
    };

    var backend = DefaultStorage.init(testing.io, testing.allocator);
    var persistence_state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });
    var kgc = try persistence.KgcPersistence.init(testing.io, testing.allocator, &persistence_state, "connection-blocked-writer.kgc");
    var memory_store = store.MemoryStore.init(testing.allocator, &.{backend.storage()}, kgc.snapshot(), null);
    var data_store = memory_store.store();
    defer data_store.deinit();
    const value = try testing.allocator.alloc(u8, 1024 * 1024);
    defer testing.allocator.free(value);
    @memset(value, 'x');
    _ = try data_store.set(.{ .key = "fruit", .value = value, .condition = null, .expires_at = null, .response = null }, 0);

    var test_logger = logging.TestLogger.init();
    var manager = ConnectionManager.init(testing.io, testing.allocator, test_logger.logger(), &data_store, 128);
    var stopped = false;
    defer if (!stopped) manager.deinit() catch {};

    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var listener = try address.listen(testing.io, .{ .reuse_address = true });
    defer listener.deinit(testing.io);
    const client = try listener.socket.address.connect(testing.io, .{ .mode = .stream });
    var client_open = true;
    defer if (client_open) client.close(testing.io);
    const receive_capacity: c_int = 4096;
    try std.posix.setsockopt(client.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVBUF, std.mem.asBytes(&receive_capacity));
    const server_stream = try listener.accept(testing.io);
    const send_capacity: c_int = 4096;
    std.posix.setsockopt(server_stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDBUF, std.mem.asBytes(&send_capacity)) catch |err| {
        server_stream.close(testing.io);
        return err;
    };
    try manager.start(server_stream);

    const observer = try listener.socket.address.connect(testing.io, .{ .mode = .stream });
    defer observer.close(testing.io);
    try manager.start(try listener.accept(testing.io));

    var request_writer = client.writer(testing.io, &.{});
    try request_writer.interface.writeAll("*2\r\n$3\r\nGET\r\n$5\r\nfruit\r\n*2\r\n$3\r\nDEL\r\n$5\r\nfruit\r\n");
    try request_writer.interface.flush();

    // Read only the header. The 1 MiB body cannot fit in these socket buffers.
    var header: ["$1048576\r\n".len]u8 = undefined;
    var received: usize = 0;
    const read_deadline: std.Io.Timeout = .{ .deadline = .fromNow(testing.io, .{ .raw = .fromSeconds(3), .clock = .awake }) };
    while (received < header.len) {
        const message = try client.socket.receiveTimeout(testing.io, header[received..], read_deadline);
        if (message.data.len == 0) return error.PrematureReplyEnd;
        received += message.data.len;
    }
    try testing.expectEqualStrings("$1048576\r\n", &header);

    // Another connection still acquires storage and finishes its reply.
    var observer_writer = observer.writer(testing.io, &.{});
    try observer_writer.interface.writeAll("*1\r\n$6\r\nDBSIZE\r\n");
    try observer_writer.interface.flush();
    var observer_reply: [4]u8 = undefined;
    received = 0;
    while (received < observer_reply.len) {
        const message = try observer.socket.receiveTimeout(testing.io, observer_reply[received..], read_deadline);
        if (message.data.len == 0) return error.PrematureReplyEnd;
        received += message.data.len;
    }
    try testing.expectEqualStrings(":1\r\n", &observer_reply);

    var shutdown: Shutdown = .{ .manager = &manager };
    const thread = try std.Thread.spawn(.{}, Shutdown.run, .{&shutdown});
    const finished_in_time = finished: {
        shutdown.done.waitTimeout(testing.io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } }) catch {
            // Release a stuck writer so a regression fails without hanging the suite.
            client.close(testing.io);
            client_open = false;
            break :finished false;
        };
        break :finished true;
    };
    thread.join();
    stopped = true;
    try testing.expect(finished_in_time);
    try shutdown.result;
    try manager.deinit();

    try testing.expectEqual(1, try data_store.dbsize(0));
    try testing.expectEqual(0, test_logger.recordedEvents().len);
}

test "reapFinished reclaims a completed worker without closing an active worker" {
    const testing = std.testing;
    var network = TestNetwork.init(testing.io, 1);
    network.immediate_eof_handle = @intCast(1);
    var mock = store.MockStore.init();
    var data_store = mock.store();
    var manager = ConnectionManager.initWithOptions(
        network.io(),
        testing.allocator,
        logging.NoopLogger.logger(),
        &data_store,
        1024,
        .{ .local_endpoint = TestNetwork.localEndpoint },
    );
    errdefer manager.deinit() catch {};

    try manager.start(TestNetwork.stream(1));
    network.immediate_closed.waitUncancelable(testing.io);
    try manager.start(TestNetwork.stream(2));
    network.all_reads_started.waitUncancelable(testing.io);

    try manager.reapFinished();
    try testing.expectEqual(1, network.close_calls.load(.acquire));
    try testing.expectEqual(0, network.shutdown_calls.load(.acquire));

    try manager.deinit();
    try testing.expectEqual(2, network.close_calls.load(.acquire));
    try testing.expectEqual(1, network.shutdown_calls.load(.acquire));
}
