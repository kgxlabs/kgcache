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
