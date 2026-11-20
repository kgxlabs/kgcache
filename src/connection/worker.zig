const std = @import("std");
const time = @import("../time.zig");
const store = @import("../store.zig");
const ClientSession = @import("session.zig");
const ClientRegistry = @import("client_registry.zig");
const Poller = @import("poller.zig");

const ClientWorker = @This();

_io: std.Io,
_allocator: std.mem.Allocator,
_store: *store.Store,
// array list of `Session pointers` to make sure that moving items around wont have unexpceted/invalid reads
client_sessions: std.ArrayList(*ClientSession) = .empty,
_poller: Poller.Interface,
_registry: *ClientRegistry,
_thread: std.Thread,
_queue: SessionQueue,
_buffer_size: usize,
_event_buffer: Poller.Interface.EventBuffer,
// wait indefintely until an event arrives
_timeout: ?time.DurationMs = null,
lifecycle: LifeCycle = .not_started,

pub const SessionQueue = std.Io.Queue(PendingSession);
pub const PendingSession = struct {
    id: u64,
    stream: std.Io.net.Stream,
};
pub const SessionId = ClientSession.SessionId;

pub const ActivationOutcome = enum {
    abort,
    run,
};

pub const LifeCycle = enum { not_started, initialized, started, stop_requested, closing, closed };

pub const SpawnWorkerFn = *const fn (*ClientWorker) std.Thread.SpawnError!std.Thread;

pub const InitConfig = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    store: *store.Store,
    registry: *ClientRegistry,
    buffer_size: usize,
    spawn_worker: spawnWorkerThread,
};

// TODO: research what is the best and efficient of creating a thread when new worker is initialized
// 1. idle thread (thread with no client sessions)
// 2. clean up when no client session and re-create when needed (expensive)
pub fn init(config: InitConfig) !ClientWorker {
    const poller = try Poller.init();

    return .{
        ._io = config.io,
        ._allocator = config.allocator,
        .store = config.store,
        ._poller = poller,
        ._registry = config.registry,
        ._buffer_size = config.buffer_size,
        ._event_buffer = undefined,
        .lifecycle = .initialized,
    };
}

pub fn deinit(self: *ClientWorker) !void {
    self.lifecycle = .closing;

    for (self.client_sessions) |_| {
        // TODO: implement clean up
    }

    self.lifecycle = .closed;
}

pub fn start(self: *ClientWorker) !void {
    // start thread
    self._thread = try self.spawnWorkerThread();

    self.lifecycle = .started;
}

// TODO: implement
// enqueue the incoming session to the fifo queue and wake the poller
pub fn register(self: *ClientWorker, session: PendingSession) !*ClientSession {
    const put_count = try self._queue.put(self.io, &.{session}, 0);
    // 0 means no capacity in queue yet hence busy worker
    if (put_count == 0) return error.WorkerBusy;

    try self._poller.wake();
}

pub fn run(self: *ClientWorker) !void {
    const events = try self._poller.wait(&self._event_buffer, self._timeout);
    for (events) |event| {
        switch (event) {
            .socket_ready => |ready| {
                try self.handleSocketReady(ready);
            },
            .wakeup => {
                try self.registerPendingSessions();
            },
        }
    }
}

// Whether or not worker is handling client sessions
pub fn isIdle() !bool {
    // TODO: implement
    return true;
}

// TODO: Drain the queues and process one by one (within budget?????)
fn registerPendingSessions(self: *ClientWorker) !void {}

// TODO: handle session input and output buffers within budget
fn handleSocketReady(self: *ClientWorker, ready_event: Poller.Interface.Event.SocketReady) !void {}

fn spawnWorkerThread(self: *ClientWorker) std.Thread.SpawnError!std.Thread {
    return std.Thread.spawn(.{}, run, .{self});
}
