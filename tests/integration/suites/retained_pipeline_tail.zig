const std = @import("std");
const support = @import("server_process");
const resp_client = @import("../harness/resp_client.zig");

pub fn run(io: std.Io, allocator: std.mem.Allocator, executable_path: []const u8, artifact_dir: ?[]const u8) !void {
    std.log.info("integration: retained pipeline tail started", .{});
    const server = try support.ServerProcess.create(io, allocator, executable_path, .{
        .artifact_dir = artifact_dir,
        .extra_config = "connection-buffer-size 36\n",
    });
    defer server.destroy();
    errdefer server.failed = true;

    const client = try server.address.?.connect(io, .{ .mode = .stream });
    {
        defer client.close(io);
        const observer = try server.address.?.connect(io, .{ .mode = .stream });
        defer observer.close(io);

        const prefix = "*1\r\n$4\r\nPING\r\n" ++
            "*3\r\n$3\r\nSET\r\n$5\r\nfruit\r\n$5\r\napple\r\n" ++
            "*2\r\n$3\r\nGET\r\n$5\r\nfruit\r\n" ++
            "*3\r\n$3\r\nSET\r\n$5\r\nfruit\r\n$20\r\nban";
        try resp_client.sendAndExpect(io, server, client.socket.handle, prefix, "+PONG\r\n+OK\r\n$5\r\napple\r\n");
        try resp_client.sendAndExpect(io, server, observer.socket.handle, "*2\r\n$3\r\nGET\r\n$5\r\nfruit\r\n", "$5\r\napple\r\n");

        try resp_client.sendAndExpect(io, server, client.socket.handle, "ana banana banana\r\n", "+OK\r\n");
        try resp_client.sendAndExpect(io, server, observer.socket.handle, "*2\r\n$3\r\nGET\r\n$5\r\nfruit\r\n", "$20\r\nbanana banana banana\r\n");
        try resp_client.sendAndExpect(io, server, client.socket.handle, "*1\r\n$4\r\nPING\r\n*1\r\n$6\r\nDBSIZE\r\n", "+PONG\r\n:1\r\n");
    }

    try server.stop();
    std.log.info("integration: retained pipeline tail passed", .{});
}
