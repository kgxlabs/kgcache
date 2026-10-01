const std = @import("std");
const support = @import("server_process");
const resp_client = @import("../harness/resp_client.zig");

pub fn run(io: std.Io, allocator: std.mem.Allocator, executable_path: []const u8, artifact_dir: ?[]const u8) !void {
    std.log.info("integration: SELECT isolation baseline started", .{});
    const server = try support.ServerProcess.create(io, allocator, executable_path, .{ .artifact_dir = artifact_dir });
    defer server.destroy();
    errdefer server.failed = true;

    const client = try server.address.?.connect(io, .{ .mode = .stream });
    {
        defer client.close(io);
        const fd = client.socket.handle;
        const get_key = "*2\r\n$3\r\nGET\r\n$3\r\nkey\r\n";

        try resp_client.sendAndExpect(io, server, fd, "*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$4\r\nzero\r\n", "+OK\r\n");
        try resp_client.sendAndExpect(io, server, fd, "*2\r\n$6\r\nSELECT\r\n$1\r\n1\r\n", "+OK\r\n");
        try resp_client.sendAndExpect(io, server, fd, get_key, "$-1\r\n");
        try resp_client.sendAndExpect(io, server, fd, "*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$3\r\none\r\n", "+OK\r\n");
        try resp_client.sendAndExpect(io, server, fd, get_key, "$3\r\none\r\n");
        try resp_client.sendAndExpect(io, server, fd, "*2\r\n$6\r\nSELECT\r\n$1\r\n0\r\n", "+OK\r\n");
        try resp_client.sendAndExpect(io, server, fd, get_key, "$4\r\nzero\r\n");
    }

    try server.stop();
    std.log.info("integration: SELECT isolation baseline passed", .{});
}
