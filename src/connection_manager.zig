const std = @import("std");
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

/// Consumes an accepted stream.
///
/// ConnectionManager is responsible for closing the stream on every return
/// path. A successful start transfers the final close to the worker. A failed
/// start closes the stream before returning the source error.
pub fn start(self: *ConnectionManager, stream: std.Io.net.Stream) !void {
    stream.close(self._io);
    return error.ConnectionWorkerStartNotImplemented;
}

pub fn reapFinished(_: *ConnectionManager) !void {}

pub fn deinit(_: *ConnectionManager) !void {
    // Worker draining and record cleanup are implemented in step 4.
}

test "connection manager boundary compiles" {
    std.testing.refAllDecls(ConnectionManager);
    std.testing.refAllDecls(ClientWorker);
}
