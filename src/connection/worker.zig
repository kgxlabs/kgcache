const std = @import("std");
const ClientSession = @import("session.zig");
const ClientRegistry = @import("client_registry.zig");

const ClientWorker = @This();

client_registry: *ClientRegistry,
stream: std.Io.net.Stream,
// Moving these pointers does not move the allocated sessions.
client_sessions: std.ArrayList(*ClientSession) = .empty,
thread: ?std.Thread = null,
lifecycle: Lifecycle = .starting,
activation_event: std.Io.Event = .unset,
activation_outcome: ActivationOutcome = .abort,

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
