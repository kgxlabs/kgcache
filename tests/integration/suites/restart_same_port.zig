const std = @import("std");
const support = @import("server_process");
const resp_client = @import("../harness/resp_client.zig");

pub fn run(io: std.Io, allocator: std.mem.Allocator, executable_path: []const u8, artifact_dir: ?[]const u8) !void {
    std.log.info("integration: restart on selected port baseline started", .{});
    const server = try support.ServerProcess.create(io, allocator, executable_path, .{ .artifact_dir = artifact_dir });
    defer server.destroy();
    errdefer server.failed = true;

    const selected_port = server.address.?.getPort();
    try expectPing(io, server);

    try server.stop();
    try server.start();
    if (server.address.?.getPort() != selected_port) return error.RestartChangedPort;
    try expectPing(io, server);

    try server.stop();
    std.log.info("integration: restart on selected port baseline passed", .{});
}

fn expectPing(io: std.Io, server: *support.ServerProcess) !void {
    const client = try server.address.?.connect(io, .{ .mode = .stream });
    defer client.close(io);
    try resp_client.sendAndExpect(io, server, client.socket.handle, "*1\r\n$4\r\nPING\r\n", "+PONG\r\n");
}
