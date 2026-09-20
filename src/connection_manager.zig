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
_stopping: std.atomic.Value(bool) = .init(false),

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

    worker.thread = try std.Thread.spawn(.{}, runWorker, .{ self, worker });
    worker.lifecycle = .running;
}

pub fn reapFinished(self: *ConnectionManager) !void {
    while (true) {
        const worker = blk: {
            var lock_tx = try self._lock.begin();
            defer lock_tx.end();

            for (self._workers.items, 0..) |candidate, index| {
                if (candidate.lifecycle == .finished) {
                    break :blk self._workers.swapRemove(index);
                }
            }
            break :blk null;
        };

        const finished_worker = worker orelse return;
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
