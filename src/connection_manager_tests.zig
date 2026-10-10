const std = @import("std");
const logging = @import("logger.zig");
const store = @import("store.zig");
const TestHelpers = @import("tests/helpers.zig");
const ConnectionManager = @import("connection_manager.zig");
const ClientWorker = ConnectionManager.ClientWorker;

test "connection manager boundary compiles" {
    std.testing.refAllDecls(ConnectionManager);
    std.testing.refAllDecls(ClientWorker);
}

test "connection IDs and borrowed contexts stay stable as the collection grows" {
    const testing = std.testing;
    const worker_count = 16;
    var network = TestHelpers.TestNetwork.init(testing.io, worker_count);
    var mock = store.MockStore.init();
    var data_store = mock.store();
    var manager = ConnectionManager.init(network.io(), testing.allocator, logging.NoopLogger.logger(), &data_store, 1024);
    defer manager.deinit() catch unreachable;

    try manager.start(TestHelpers.TestNetwork.stream(1));
    const first_context = &manager._workers.items[0].context;
    for (2..worker_count + 1) |handle| {
        try manager.start(TestHelpers.TestNetwork.stream(handle));
    }
    network.all_reads_started.waitUncancelable(testing.io);

    var lock_tx = try manager._lock.begin();
    defer lock_tx.end();
    try testing.expect(&manager._workers.items[0].context == first_context);
    for (manager._workers.items, 1..) |worker, expected_id| {
        try testing.expectEqual(@as(u64, expected_id), worker.context.id);
    }
}

test "connection IDs are never reused after finished workers are reaped" {
    const testing = std.testing;
    var network = TestHelpers.TestNetwork.init(testing.io, 0);
    network.immediate_eof_handle = 1;
    var mock = store.MockStore.init();
    var data_store = mock.store();
    var manager = ConnectionManager.init(network.io(), testing.allocator, logging.NoopLogger.logger(), &data_store, 1024);
    defer manager.deinit() catch unreachable;

    for (1..4) |expected_id| {
        network.immediate_closed.reset();
        try manager.start(TestHelpers.TestNetwork.stream(1));
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
    var network = TestHelpers.TestNetwork.init(testing.io, 1);
    var mock = store.MockStore.init();
    var data_store = mock.store();
    var manager = ConnectionManager.init(
        network.io(),
        testing.allocator,
        logging.NoopLogger.logger(),
        &data_store,
        1024,
    );
    errdefer manager.deinit() catch {};

    try manager.start(TestHelpers.TestNetwork.stream(1));
    network.all_reads_started.waitUncancelable(testing.io);
    try manager.deinit();
    try manager.deinit();

    try testing.expectEqual(1, network.shutdown_calls.load(.acquire));
    try testing.expectEqual(1, network.close_calls.load(.acquire));
}

test "deinit wakes every idle worker before any worker closes" {
    const testing = std.testing;
    const worker_count = 4;
    var network = TestHelpers.TestNetwork.init(testing.io, worker_count);
    var mock = store.MockStore.init();
    var data_store = mock.store();
    var manager = ConnectionManager.init(
        network.io(),
        testing.allocator,
        logging.NoopLogger.logger(),
        &data_store,
        1024,
    );
    errdefer manager.deinit() catch {};

    for (1..worker_count + 1) |handle| {
        try manager.start(TestHelpers.TestNetwork.stream(handle));
    }
    network.all_reads_started.waitUncancelable(testing.io);
    try manager.deinit();

    try testing.expectEqual(worker_count, network.shutdown_calls.load(.acquire));
    try testing.expectEqual(worker_count, network.close_calls.load(.acquire));
    try testing.expect(!network.close_before_all_shutdown.load(.acquire));
}

test "deinit wakes a real blocked writer and idle reader before joining" {
    const testing = std.testing;
    const DefaultStorage = @import("storage/default_storage.zig");
    const PersistenceState = @import("persistence_state.zig");
    const persistence = @import("persistence.zig");
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
    var network = TestHelpers.TestNetwork.init(testing.io, 1);
    network.immediate_eof_handle = @intCast(1);
    var mock = store.MockStore.init();
    var data_store = mock.store();
    var manager = ConnectionManager.init(
        network.io(),
        testing.allocator,
        logging.NoopLogger.logger(),
        &data_store,
        1024,
    );
    errdefer manager.deinit() catch {};

    try manager.start(TestHelpers.TestNetwork.stream(1));
    network.immediate_closed.waitUncancelable(testing.io);
    try manager.start(TestHelpers.TestNetwork.stream(2));
    network.all_reads_started.waitUncancelable(testing.io);

    try manager.reapFinished();
    try testing.expectEqual(1, network.close_calls.load(.acquire));
    try testing.expectEqual(0, network.shutdown_calls.load(.acquire));

    try manager.deinit();
    try testing.expectEqual(2, network.close_calls.load(.acquire));
    try testing.expectEqual(1, network.shutdown_calls.load(.acquire));
}
