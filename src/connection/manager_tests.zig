const std = @import("std");
const logging = @import("../logger.zig");
const store = @import("../store.zig");
const TestNetwork = @import("test_network.zig");
const ConnectionManager = @import("../connection.zig").ConnectionManager;
const ClientWorker = ConnectionManager.ClientWorker;
const socket_metadata = @import("socket_metadata.zig");

test "connection manager boundary compiles" {
    std.testing.refAllDecls(ConnectionManager);
    std.testing.refAllDecls(ClientWorker);
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
        try testing.expect(worker.context.reports.?.ptr == @as(*anyopaque, worker));
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
        {
            var tx = worker.report._lock.beginUncancelable();
            defer tx.end();
            worker.report._values.lib_name = "test-library";
            worker.report._values.lib_ver = "1.2.3";
        }
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
