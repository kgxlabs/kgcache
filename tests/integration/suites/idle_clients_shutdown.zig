const std = @import("std");
const support = @import("server_process");
const resp_client = @import("../harness/resp_client.zig");

pub fn run(io: std.Io, allocator: std.mem.Allocator, executable_path: []const u8, artifact_dir: ?[]const u8) !void {
    std.log.info("integration: idle clients shutdown baseline started", .{});
    const server = try support.ServerProcess.create(io, allocator, executable_path, .{ .artifact_dir = artifact_dir });
    defer server.destroy();
    errdefer server.failed = true;

    var clients: [4]std.Io.net.Stream = undefined;
    var connected: usize = 0;
    defer {
        for (clients[0..connected]) |client| client.close(io);
    }

    while (connected < clients.len) {
        const client = try server.address.?.connect(io, .{ .mode = .stream });
        clients[connected] = client;
        connected += 1;
        try resp_client.sendAndExpect(io, server, client.socket.handle, "*1\r\n$4\r\nPING\r\n", "+PONG\r\n");
    }

    try server.stop();
    std.log.info("integration: idle clients shutdown baseline passed", .{});
}
