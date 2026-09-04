const std = @import("std");
const Config = @import("config.zig");
const Server = @import("server.zig");

pub fn main(init: std.process.Init) !void {
    const config = try Config.loadFromArgs(init);

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    const server = try Server.create(init.io, gpa.allocator(), config);
    defer server.destroy();

    installShutdownHandlers(server);
    try server.run();
}

fn installShutdownHandlers(server: *Server) void {
    // TODO: route SIGINT/SIGTERM through Server.run's orderly
    // listener, cron, and AOF shutdown sequence.
    _ = server;
}
