const std = @import("std");
const ClientSession = @import("session.zig");
const ClientRegistry = @import("client_registry.zig");

const ClientWorker = @This();

// array list of `Session pointers` to make sure that moving items around wont have unexpceted/invalid reads
client_sessions: std.ArrayList(*ClientSession) = .empty,
// TODO: figure out if we need this here or in lifecycle
_lifecycle: Lifecycle = .starting,
_stream: std.Io.net.Stream,
_registry: *ClientRegistry,

pub const ActivationOutcome = enum {
    abort,
    run,
};

pub const Lifecycle = enum {
    starting,
    running,
    stopping,
    finished,
};

pub fn init(io: std.Io, allocator: std.mem.Allocator, stream: std.Io.net.Stream, registry: *ClientRegistry) !ClientWorker {
    return .{
        ._registry = registry,
        ._stream = stream,
    };
}
