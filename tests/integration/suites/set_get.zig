const std = @import("std");
const support = @import("server_process");
const resp_client = @import("../harness/resp_client.zig");

pub fn run(io: std.Io, allocator: std.mem.Allocator, executable_path: []const u8, artifact_dir: ?[]const u8) !void {
    std.log.info("integration: SET/GET and DEL semantics started", .{});
    const server = try support.ServerProcess.create(io, allocator, executable_path, .{ .artifact_dir = artifact_dir });
    defer server.destroy();
    errdefer server.failed = true;

    const client = try server.address.?.connect(io, .{ .mode = .stream });
    {
        defer client.close(io);
        try resp_client.sendAndExpect(io, server, client.socket.handle, "*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$5\r\nvalue\r\n", "+OK\r\n");
        try resp_client.sendAndExpect(io, server, client.socket.handle, "*2\r\n$3\r\nGET\r\n$3\r\nkey\r\n", "$5\r\nvalue\r\n");
        try resp_client.sendAndExpect(io, server, client.socket.handle, "*3\r\n$3\r\nSET\r\n$6\r\nsecond\r\n$2\r\nv2\r\n", "+OK\r\n");
        try resp_client.sendAndExpect(io, server, client.socket.handle, "*3\r\n$3\r\nSET\r\n$9\r\nuntouched\r\n$4\r\nkeep\r\n", "+OK\r\n");

        try resp_client.sendAndExpect(io, server, client.socket.handle, "*6\r\n$3\r\nDEL\r\n$3\r\nkey\r\n$7\r\nmissing\r\n$6\r\nsecond\r\n$3\r\nkey\r\n$6\r\nsecond\r\n", ":2\r\n");
        try resp_client.sendAndExpect(io, server, client.socket.handle, "*2\r\n$3\r\nGET\r\n$3\r\nkey\r\n", "$-1\r\n");
        try resp_client.sendAndExpect(io, server, client.socket.handle, "*2\r\n$3\r\nGET\r\n$6\r\nsecond\r\n", "$-1\r\n");
        try resp_client.sendAndExpect(io, server, client.socket.handle, "*4\r\n$3\r\nDEL\r\n$3\r\nkey\r\n$7\r\nmissing\r\n$6\r\nsecond\r\n", ":0\r\n");
        try resp_client.sendAndExpect(io, server, client.socket.handle, "*2\r\n$3\r\nGET\r\n$9\r\nuntouched\r\n", "$4\r\nkeep\r\n");
        try resp_client.sendAndExpect(io, server, client.socket.handle, "*1\r\n$6\r\nDBSIZE\r\n", ":1\r\n");
    }

    try server.stop();
    std.log.info("integration: SET/GET and DEL semantics passed", .{});
}
