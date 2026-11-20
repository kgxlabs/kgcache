const std = @import("std");
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
_poller: Poller.Poller,
_registry: *ClientRegistry,
_thread: std.Thread,
_queue: SessionQueue,
_buffer_size: usize,

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
    };
}

pub fn deinit(self: *ClientWorker) !void {
    for (self.client_sessions) |_| {
        // TODO: implement clean up
    }
}

pub fn start(self: *ClientWorker) !void {
    // start thread
    self._thread = try self.spawnWorkerThread();
}

// TODO: implement
// enqueue the incoming session to the fifo queue and wake the poller
pub fn register(self: *ClientWorker, session: PendingSession) !*ClientSession {}

// Long running event loop to process owned sessions one by one
pub fn run(self: *ClientWorker) !void {}

// Whether or not worker is handling client sessions
pub fn isIdle() !bool {
    // TODO: implement
    return true;
}

fn spawnWorkerThread(self: *ClientWorker) std.Thread.SpawnError!std.Thread {
    return std.Thread.spawn(.{}, run, .{self});
}
