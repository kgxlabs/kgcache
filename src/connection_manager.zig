const std = @import("std");
const connection = @import("connection.zig");
const Lock = @import("lock.zig");
const logging = @import("logger.zig");
const store = @import("store.zig");
const TestHelpers = @import("tests/helpers.zig");

const ConnectionManager = @This();
// TODO: If this is too much, reduce it.
const max_reaped_workers_per_pass: usize = 64;

pub const SpawnWorkerFn = *const fn (*ConnectionManager, *ClientWorker) std.Thread.SpawnError!std.Thread;

const Options = struct {
    /// Allows deterministic thread-spawn failure injection in lifecycle tests.
    spawn_worker: SpawnWorkerFn = spawnWorkerThread,
};

/// A stable, heap-allocated record owned by ConnectionManager.
pub const ClientWorker = struct {
    pub const Lifecycle = enum {
        starting,
        running,
        stopping,
        finished,
    };

    stream: std.Io.net.Stream,
    thread: ?std.Thread = null,
    lifecycle: Lifecycle = .starting,
};

_io: std.Io,
_allocator: std.mem.Allocator,
// Borrowed dependencies. Their owners must keep them alive until deinit returns.
_logger: logging.Logger,
_store: *store.Store,
_connection_buffer_size: usize,
// Coordinates worker registration, completion, shutdown, and stream close.
_lock: Lock,
_workers: std.ArrayList(*ClientWorker) = .empty,
_stopping: std.atomic.Value(bool) = .init(false),
_spawn_worker: SpawnWorkerFn,

pub fn init(
    io: std.Io,
    allocator: std.mem.Allocator,
    logger: logging.Logger,
    data_store: *store.Store,
    connection_buffer_size: usize,
) ConnectionManager {
    return initWithOptions(io, allocator, logger, data_store, connection_buffer_size, .{});
}

fn initWithOptions(
    io: std.Io,
    allocator: std.mem.Allocator,
    logger: logging.Logger,
    data_store: *store.Store,
    connection_buffer_size: usize,
    options: Options,
) ConnectionManager {
    return .{
        ._io = io,
        ._allocator = allocator,
        ._logger = logger,
        ._store = data_store,
        ._connection_buffer_size = connection_buffer_size,
        ._lock = Lock.init(io),
        ._spawn_worker = options.spawn_worker,
    };
}

/// ConnectionManager consumes the stream on every return path. A successful
/// start transfers the final close to the worker completion path. A failed
/// start closes the stream before returning the source error.
pub fn start(self: *ConnectionManager, stream: std.Io.net.Stream) !void {
    errdefer stream.close(self._io);

    const worker = try self._allocator.create(ClientWorker);
    errdefer self._allocator.destroy(worker);
    worker.* = .{ .stream = stream };

    var lock_tx = try self._lock.begin();
    defer lock_tx.end();

    if (self._stopping.load(.acquire)) return error.ConnectionManagerStopping;

    try self._workers.append(self._allocator, worker);
    errdefer std.debug.assert(self._workers.pop().? == worker);

    worker.thread = try self._spawn_worker(self, worker);
    worker.lifecycle = .running;
}

pub fn reapFinished(self: *ConnectionManager) !void {
    var finished_workers: [max_reaped_workers_per_pass]*ClientWorker = undefined;
    var finished_count: usize = 0;

    {
        var lock_tx = try self._lock.begin();
        defer lock_tx.end();

        var index: usize = 0;
        while (index < self._workers.items.len and finished_count < max_reaped_workers_per_pass) {
            const worker = self._workers.items[index];

            if (worker.lifecycle == .finished) {
                finished_workers[finished_count] = self._workers.swapRemove(index);
                finished_count += 1;
            } else {
                index += 1;
            }
        }
    }

    for (finished_workers[0..finished_count]) |finished_worker| {
        finished_worker.thread.?.join();
        self._allocator.destroy(finished_worker);
    }
}

pub fn deinit(self: *ConnectionManager) !void {
    var first_error: ?anyerror = null;
    var draining_workers: std.ArrayList(*ClientWorker) = .empty;

    {
        var lock_tx = self._lock.beginUncancelable();
        defer lock_tx.end();

        self._stopping.store(true, .release);

        for (self._workers.items) |worker| {
            switch (worker.lifecycle) {
                .starting, .running => worker.lifecycle = .stopping,
                .stopping, .finished => {},
            }
        }

        for (self._workers.items) |worker| {
            if (worker.lifecycle != .stopping) continue;
            worker.stream.shutdown(self._io, .recv) catch |err| switch (err) {
                error.SocketUnconnected => {},
                else => if (first_error == null) {
                    first_error = err;
                },
            };
        }

        draining_workers = self._workers;
        self._workers = .empty;
    }

    for (draining_workers.items) |worker| {
        worker.thread.?.join();
        self._allocator.destroy(worker);
    }
    draining_workers.deinit(self._allocator);

    if (first_error) |err| return err;
}

fn runWorker(self: *ConnectionManager, worker: *ClientWorker) void {
    connection.serve(
        self._io,
        self._logger,
        worker.stream,
        self._store,
        self._allocator,
        self._connection_buffer_size,
        &self._stopping,
    );
    self.finishWorker(worker);
}

fn spawnWorkerThread(self: *ConnectionManager, worker: *ClientWorker) std.Thread.SpawnError!std.Thread {
    return std.Thread.spawn(.{}, runWorker, .{ self, worker });
}

// This runs on the worker thread, so joining here would wait on itself.
// The accept-loop reaper or deinit joins and frees the finished record.
fn finishWorker(self: *ConnectionManager, worker: *ClientWorker) void {
    var lock_tx = self._lock.beginUncancelable();
    defer lock_tx.end();

    worker.stream.close(self._io);
    worker.lifecycle = .finished;
}

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

test "thread spawn failure returns its source and closes the stream once" {
    const testing = std.testing;
    const failSpawn = struct {
        fn spawn(_: *ConnectionManager, _: *ClientWorker) std.Thread.SpawnError!std.Thread {
            return error.ThreadQuotaExceeded;
        }
    }.spawn;

    var network = TestHelpers.TestNetwork.init(testing.io, 0);
    var mock = store.MockStore.init();
    var data_store = mock.store();
    var manager = ConnectionManager.initWithOptions(
        network.io(),
        testing.allocator,
        logging.NoopLogger.logger(),
        &data_store,
        1024,
        .{ .spawn_worker = failSpawn },
    );
    errdefer manager.deinit() catch {};

    try testing.expectError(error.ThreadQuotaExceeded, manager.start(TestHelpers.TestNetwork.stream(1)));
    try testing.expectEqual(1, network.close_calls.load(.acquire));
    try manager.deinit();
}
