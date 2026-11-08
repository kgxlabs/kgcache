const std = @import("std");
const store = @import("../store.zig");
const ClientSession = @import("session.zig");
const ClientRegistry = @import("client_registry.zig");

const ClientWorker = @This();

_io: std.Io,
_allocator: std.mem.Allocator,
_store: *store.Store,
// array list of `Session pointers` to make sure that moving items around wont have unexpceted/invalid reads
client_sessions: std.ArrayList(*ClientSession) = .empty,
_registry: *ClientRegistry,
_thread: std.Thread,

pub const ActivationOutcome = enum {
    abort,
    run,
};

// TODO: research what is the best and efficient of creating a thread when new worker is initialized
// 1. idle thread (thread with no client sessions)
// 2. clean up when no client session and re-create when needed (expensive)
pub fn init(
    io: std.Io,
    allocator: std.mem.Allocator,
    data_store: *store.Store,
    registry: *ClientRegistry,
) !ClientWorker {
    return .{
        ._io = io,
        ._allocator = allocator,
        .store = data_store,
        ._registry = registry,
    };
}

pub fn deinit(self: *ClientWorker) !void {
    for (self.client_sessions) |_| {
        // TODO: implement clean up
    }
}

// TODO: implement
pub fn register(self: *ClientWorker, stream: std.Io.net.Stream) !*ClientSession {
    const session = try self._allocator.create(ClientSession);
    errdefer self._allocator.destroy(session);

    session.* = ClientSession.init(.{
        .io = self._io,
        .allocator = self._allocator,
        .stream = stream,
    });
    return session;
}

// Whether or not worker is handling client sessions
pub fn isIdle() !bool {
    // TODO: implement
    return true;
}
