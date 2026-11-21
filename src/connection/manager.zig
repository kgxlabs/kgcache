const std = @import("std");
const ConnectionContext = @import("context.zig");
const ConnectionReport = @import("report.zig");
const ClientWorker = @import("worker.zig");
const ClientRegistry = @import("client_registry.zig");
const WorkerSelector = @import("worker_selector.zig");
const Lock = @import("../lock.zig");
const socket_metadata = @import("socket_metadata.zig");
const logging = @import("../logger.zig");
const store = @import("../store.zig");
const TestNetwork = @import("test_network.zig");
const protocol = @import("../protocol.zig");

const ConnectionManager = @This();
// TODO: If this is too much, reduce it.
const max_reaped_workers_per_pass: usize = 64;

pub const SpawnWorkerFn = *const fn (*ConnectionManager, *ClientWorker) std.Thread.SpawnError!std.Thread;
pub const LocalEndpointFn = *const fn (std.Io, std.Io.net.Socket.Handle) anyerror!std.Io.net.IpAddress;
pub const Options = struct { local_endpoint: LocalEndpointFn = socket_metadata.localEndpoint };

_io: std.Io,
_allocator: std.mem.Allocator,
// Borrowed dependencies. Their owners must keep them alive until deinit returns.
_logger: logging.Logger,
_store: *store.Store,
_worker_count: u16,
_connection_buffer_size: usize,
// Coordinates worker registration, completion, shutdown, and stream close.
_lock: Lock,
// Owns registry storage. Sessions own the indexed clients.
_registry: ClientRegistry,
_registry_released: bool = false,
_workers: std.ArrayList(*ClientWorker) = .empty,
// Owns selector state. Borrowed handles are created after the manager is placed.
_worker_selector: WorkerSelector.LinearScan,
_next_connection_id: ClientWorker.SessionId = 1,
_stopping: std.atomic.Value(bool) = .init(false),
_spawn_worker: SpawnWorkerFn,
_local_endpoint: LocalEndpointFn,

// TODO: refactor so that we dont need another init method just for options
pub fn init(
    io: std.Io,
    allocator: std.mem.Allocator,
    logger: logging.Logger,
    data_store: *store.Store,
    connection_buffer_size: usize,
) ConnectionManager {
    return initWithOptions(
        io,
        allocator,
        logger,
        data_store,
        connection_buffer_size,
        .{},
    );
}

pub fn initWithOptions(
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
        ._registry = ClientRegistry.init(io, allocator),
        ._worker_selector = WorkerSelector.LinearScan.init(io, allocator),
        ._spawn_worker = options.spawn_worker,
        ._local_endpoint = options.local_endpoint,
    };
}

// ConnectionManager will start the workers to a defined limit and make them start and list for events in their own threads
pub fn start(self: *ConnectionManager, thread_count: u16) !void {
    const previous_worker_count = self._workers.items.len;
    if (thread_count == 0 or thread_count > WorkerSelector.Interface.max_workers - previous_worker_count) {
        return error.InvalidWorkerCount;
    }
    const selector = self._worker_selector.selector();

    errdefer {
        while (self._workers.items.len > previous_worker_count) {
            const worker = self._workers.pop().?;
            self.destroyWorker(worker);
        }
    }

    for (0..thread_count) |_| {
        const worker_id: WorkerSelector.Interface.WorkerId = @intCast(self._workers.items.len);
        const worker = try self.createWorker(worker_id);
        errdefer self.destroyWorker(worker);

        try selector.addWorker(worker.selectionSource());
        try worker.start();
        try self._workers.append(self._allocator, worker);
    }
}

pub fn register(self: *ConnectionManager, stream: std.Io.net.Stream) !void {
    const pending_session: ClientWorker.PendingSession = .{
        .id = self.nextConnectionId(),
        .stream = stream,
    };

    const selector = self._worker_selector.selector();
    var tried_workers = WorkerSelector.Interface.ExcludedWorkers.initEmpty();
    while (selector.choose(tried_workers)) |worker_id| {
        tried_workers.set(worker_id);

        const worker = self._workers.items[worker_id];
        worker.register(pending_session) catch |err| {
            switch (err) {
                // TODO: figure for what other errors should we retry with next worker
                error.WorkerBusy => continue,
                else => break,
            }
        };
        // a worker took in the session and manager job is done here
        return;
    }

    // no worker accepted the conenction so close the connection
    stream.close(self._io);
    return error.ServerBusy;
}

fn createWorker(self: *ConnectionManager, worker_id: WorkerSelector.Interface.WorkerId) !*ClientWorker {
    // TODO: figure out when to do stream.close
    const worker = try self._allocator.create(ClientWorker);
    errdefer self._allocator.destroy(worker);

    worker.* = try ClientWorker.init(.{
        .io = self._io,
        .allocator = self._allocator,
        .store = self._store,
        .registry = &self._registry,
        .buffer_size = self._connection_buffer_size,
        .worker_id = worker_id,
        .worker_selector = self._worker_selector.selector(),
    });

    return worker;
}

fn runWorker(_: *ConnectionManager, _: *ClientWorker) void {
    // TODO: schedule sessions and call ClientSession.serve.
    @panic("ConnectionManager.runWorker is not implemented");
}

// TODO: destroy the provided worker, both unstarted or started
// For a started worker, this must request shutdown and join the thread
fn destroyWorker(self: *ConnectionManager, worker: *ClientWorker) void {
    self._worker_selector.selector().removeWorker(worker._worker_id);
}

fn nextConnectionId(self: *ConnectionManager) ClientWorker.SessionId {
    const current_id = self._next_connection_id;
    self._next_connection_id += 1;
    return current_id;
}

pub fn snapshotLive(self: *ConnectionManager, io: std.Io, allocator: std.mem.Allocator) ConnectionContext.Error!ConnectionContext.LiveSnapshots {
    // Membership and record lifetime stay protected until every row is copied.
    var tx = self._lock.beginUncancelable();
    defer tx.end();

    var count: usize = 0;
    for (self._workers.items) |worker| {
        if (worker.lifecycle == .running or worker.lifecycle == .stopping) count += 1;
    }
    const items = try allocator.alloc(ConnectionContext.Snapshot, count);
    var captured: usize = 0;
    errdefer {
        for (items[0..captured]) |*snapshot| snapshot.deinit();
        allocator.free(items);
    }

    for (self._workers.items) |worker| {
        if (worker.lifecycle != .running and worker.lifecycle != .stopping) continue;
        items[captured] = try worker.context.snapshotCurrent(io, allocator);
        captured += 1;
    }
    return .{ .items = items, .allocator = allocator };
}

// TODO: replace with new design
pub fn deinit(self: *ConnectionManager) !void {
    defer self._worker_selector.selector().deinit();
    var first_error: ?anyerror = null;
    var draining_workers: std.ArrayList(*ClientWorker) = .empty;

    {
        var lock_tx = self._lock.beginUncancelable();
        defer lock_tx.end();

        self._stopping.store(true, .release);

        for (self._workers.items) |worker| {
            self._worker_selector.selector().removeWorker(worker._worker_id);
            switch (worker.lifecycle) {
                .starting, .running => worker.lifecycle = .stopping,
                .stopping, .finished => {},
            }
        }

        for (self._workers.items) |worker| {
            if (worker.lifecycle != .stopping) continue;
            // NOTE: we need to shutdown both (receiving and send)
            // receive: stop receiving clients bytes
            // send: stop sending bytes to client
            worker.stream.shutdown(self._io, .both) catch |err| switch (err) {
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
        worker.report.deinit();
        self._allocator.destroy(worker);
    }
    draining_workers.deinit(self._allocator);

    if (first_error) |err| return err;
}

// This runs on the worker thread, so joining here would wait on itself.
// The accept-loop reaper or deinit joins and frees the finished record.
fn finishWorker(self: *ConnectionManager, worker: *ClientWorker) void {
    var lock_tx = self._lock.beginUncancelable();
    defer lock_tx.end();

    self._worker_selector.selector().removeWorker(worker._worker_id);
    worker.stream.close(self._io);
    worker.lifecycle = .finished;
}

test "thread spawn failure consumes its ID and closes the stream once" {
    const testing = std.testing;
    const failSpawn = struct {
        fn spawn(manager: *ConnectionManager, worker: *ClientWorker) std.Thread.SpawnError!std.Thread {
            if (worker.context.id == 1) {
                worker.context.setLibraryInfo(.lib_name, "failed-worker") catch return error.SystemResources;
                worker.context.setLibraryInfo(.lib_ver, "V1") catch return error.SystemResources;
                return error.ThreadQuotaExceeded;
            }
            return spawnWorkerThread(manager, worker);
        }
    }.spawn;

    var network = TestNetwork.init(testing.io, 1);
    var mock = store.MockStore.init();
    var data_store = mock.store();
    var manager = ConnectionManager.initWithOptions(
        network.io(),
        testing.allocator,
        logging.NoopLogger.logger(),
        &data_store,
        1024,
        .{ .spawn_worker = failSpawn, .local_endpoint = TestNetwork.localEndpoint },
    );
    errdefer manager.deinit() catch {};

    try testing.expectError(error.ThreadQuotaExceeded, manager.start(TestNetwork.stream(1)));
    try testing.expectEqual(1, network.close_calls.load(.acquire));
    try testing.expectEqual(0, manager._workers.items.len);
    var unpublished = try manager.snapshotLive(manager._io, testing.allocator);
    defer unpublished.deinit();
    try testing.expectEqual(0, unpublished.items.len);

    try manager.start(TestNetwork.stream(2));
    network.all_reads_started.waitUncancelable(testing.io);
    try testing.expectEqual(@as(u64, 2), manager._workers.items[0].context.id);
    try manager.deinit();
    try testing.expectEqual(2, network.close_calls.load(.acquire));
    try testing.expectEqual(1, network.shutdown_calls.load(.acquire));
}

test "ID exhaustion rejects registration without wrapping or closing twice" {
    const testing = std.testing;
    var network = TestNetwork.init(testing.io, 1);
    var mock = store.MockStore.init();
    var data_store = mock.store();
    var manager = ConnectionManager.initWithOptions(network.io(), testing.allocator, logging.NoopLogger.logger(), &data_store, 1024, .{ .local_endpoint = TestNetwork.localEndpoint });
    errdefer manager.deinit() catch {};
    manager._next_connection_id = std.math.maxInt(i64);

    try manager.start(TestNetwork.stream(1));
    network.all_reads_started.waitUncancelable(testing.io);
    const worker = manager._workers.items[0];
    try testing.expectEqual(@as(u64, std.math.maxInt(i64)), worker.context.id);

    for (2..4) |handle| {
        try testing.expectError(error.ConnectionIdExhausted, manager.start(TestNetwork.stream(handle)));
    }
    try testing.expectEqual(@as(u64, std.math.maxInt(i64)) + 1, manager._next_connection_id);
    try testing.expectEqual(1, manager._workers.items.len);
    try testing.expect(manager._workers.items[0] == worker);
    try testing.expectEqual(2, network.close_calls.load(.acquire));

    try manager.deinit();
    try testing.expectEqual(3, network.close_calls.load(.acquire));
    try testing.expectEqual(1, network.shutdown_calls.load(.acquire));
}

test "worker and collection allocation failures close the consumed stream once" {
    const testing = std.testing;
    for (0..2) |fail_index| {
        var network = TestNetwork.init(testing.io, 0);
        var mock = store.MockStore.init();
        var data_store = mock.store();
        var failing_allocator = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        var manager = ConnectionManager.initWithOptions(network.io(), failing_allocator.allocator(), logging.NoopLogger.logger(), &data_store, 1024, .{ .local_endpoint = TestNetwork.localEndpoint });
        errdefer manager.deinit() catch {};

        try testing.expectError(error.OutOfMemory, manager.start(TestNetwork.stream(1)));
        try testing.expectEqual(0, manager._workers.items.len);
        try testing.expectEqual(1, network.close_calls.load(.acquire));
        try manager.deinit();
        try testing.expectEqual(1, network.close_calls.load(.acquire));
    }
}
