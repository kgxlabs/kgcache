const std = @import("std");
const support = @import("server_process");

pub fn run(io: std.Io, allocator: std.mem.Allocator, executable_path: []const u8, artifact_dir: ?[]const u8) !void {
    std.log.info("integration: SET/GET baseline started", .{});
    const server = try support.ServerProcess.create(io, allocator, executable_path, .{ .artifact_dir = artifact_dir });
    defer server.destroy();
    errdefer server.failed = true;

    const client = try server.address.?.connect(io, .{ .mode = .stream });
    {
        defer client.close(io);
        try sendAndExpect(io, server, client.socket.handle, "*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$5\r\nvalue\r\n", "+OK\r\n");
        try sendAndExpect(io, server, client.socket.handle, "*2\r\n$3\r\nGET\r\n$3\r\nkey\r\n", "$5\r\nvalue\r\n");
    }

    try server.stop();
    std.log.info("integration: SET/GET baseline passed", .{});
}

fn sendAndExpect(io: std.Io, server: *support.ServerProcess, fd: std.posix.fd_t, request: []const u8, expected: []const u8) !void {
    var sent: usize = 0;
    while (sent < request.len) {
        const count = try io.vtable.netWrite(io.userdata, fd, request[sent..], &.{""}, 0);
        if (count == 0) return error.ShortRequestWrite;
        sent += count;
    }

    var reply: [32]u8 = undefined;
    std.debug.assert(expected.len <= reply.len);
    try server.readExact(fd, reply[0..expected.len]);
    if (!std.mem.eql(u8, reply[0..expected.len], expected)) {
        std.log.err("integration: expected reply {s}, got {s}", .{ expected, reply[0..expected.len] });
        return error.UnexpectedReply;
    }
}
