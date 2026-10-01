const std = @import("std");
const support = @import("server_process");
const resp_client = @import("../harness/resp_client.zig");

pub fn run(io: std.Io, allocator: std.mem.Allocator, executable_path: []const u8, artifact_dir: ?[]const u8) !void {
    std.log.info("integration: SET/GET baseline started", .{});
    const server = try support.ServerProcess.create(io, allocator, executable_path, .{ .artifact_dir = artifact_dir });
    defer server.destroy();
    errdefer server.failed = true;

    const client = try server.address.?.connect(io, .{ .mode = .stream });
    {
        defer client.close(io);
        try resp_client.sendAndExpect(io, server, client.socket.handle, "*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$5\r\nvalue\r\n", "+OK\r\n");
        try resp_client.sendAndExpect(io, server, client.socket.handle, "*2\r\n$3\r\nGET\r\n$3\r\nkey\r\n", "$5\r\nvalue\r\n");
    }

    try server.stop();
    std.log.info("integration: SET/GET baseline passed", .{});
}
