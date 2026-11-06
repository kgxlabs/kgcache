const std = @import("std");
const ClientSession = @import("session.zig");
const ClientRegistry = @import("client_registry.zig");

const ClientWorker = @This();

client_registy: *ClientRegistry,
stream: std.Io.net.Stream,
client_sessions: std.ArrayList(ClientSession) = .empty,
thread: ?std.Thread = null,
lifecycle: Lifecycle = .starting,

pub const Lifecycle = enum {
    starting,
    running,
    stopping,
    finished,
};
