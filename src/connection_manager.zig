const std = @import("std");
const connection = @import("connection.zig");
const Lock = @import("lock.zig");
const logging = @import("logger.zig");
const store = @import("store.zig");

const ConnectionManager = @This();

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
_stopping: bool = false,

pub fn init(
    io: std.Io,
    allocator: std.mem.Allocator,
    logger: logging.Logger,
    data_store: *store.Store,
    connection_buffer_size: usize,
) ConnectionManager {
    return .{
        ._io = io,
        ._allocator = allocator,
        ._logger = logger,
        ._store = data_store,
        ._connection_buffer_size = connection_buffer_size,
        ._lock = Lock.init(io),
    };
}

/// NOTE: ConnectionManager is responsible for closing the stream on every return
/// path. Since we are spwaning a thread, a successful start transfers the final close to the worker. A failed
/// start closes the stream before returning the source error.
pub fn start(self: *ConnectionManager, stream: std.Io.net.Stream) !void {
    errdefer stream.close(self._io);

    const worker = try self._allocator.create(ClientWorker);
    errdefer self._allocator.destroy(worker);
    worker.* = .{ .stream = stream };

    var lock_tx = try self._lock.begin();
    defer lock_tx.end();

    if (self._stopping) return error.ConnectionManagerStopping;

    try self._workers.append(self._allocator, worker);
    errdefer std.debug.assert(self._workers.pop().? == worker);

    worker.thread = try std.Thread.spawn(.{}, runWorker, .{ self, worker });
    worker.lifecycle = .running;
}

pub fn reapFinished(_: *ConnectionManager) !void {}

pub fn deinit(_: *ConnectionManager) !void {
    // Worker draining and record cleanup are implemented in step 4.
}

fn runWorker(self: *ConnectionManager, worker: *ClientWorker) void {
    connection.serve(
        self._io,
        self._logger,
        worker.stream,
        self._store,
        self._allocator,
        self._connection_buffer_size,
    );
    self.finishWorker(worker);
}

// NOTE: we must not join the thread here because this itself will run in a thread so it will be deadlocked.
// The responsibility of joining and removing from the list will be handled by cron reap
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
