const std = @import("std");
const support = @import("server_process");
const resp_client = @import("../harness/resp_client.zig");

pub fn run(io: std.Io, allocator: std.mem.Allocator, executable_path: []const u8, artifact_dir: ?[]const u8) !void {
    std.log.info("integration: command error recovery started", .{});
    const server = try support.ServerProcess.create(io, allocator, executable_path, .{ .artifact_dir = artifact_dir });
    defer server.destroy();
    errdefer server.failed = true;

    const client = try server.address.?.connect(io, .{ .mode = .stream });
    {
        defer client.close(io);
        const fd = client.socket.handle;
        try resp_client.sendAndExpect(io, server, fd, "*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$8\r\noriginal\r\n", "+OK\r\n");

        const cases = [_]struct { request: []const u8, response: []const u8 }{
            .{
                .request = "*4\r\n$3\r\nSET\r\n$3\r\nkey\r\n$5\r\nvalue\r\n$2\r\nEX\r\n",
                .response = "-ERR unsupported option\r\n",
            },
            .{
                .request = "*5\r\n$3\r\nSET\r\n$3\r\nkey\r\n$5\r\nvalue\r\n$2\r\nNX\r\n$2\r\nXX\r\n",
                .response = "-ERR syntax error\r\n",
            },
            .{
                .request = "*4\r\n$3\r\nSET\r\n$3\r\nkey\r\n$5\r\nvalue\r\n$12\r\nbad\x00\r\noption\r\n",
                .response = "-ERR syntax error\r\n",
            },
            .{
                .request = "*2\r\n$6\r\nBGSAVE\r\n$3\r\nNOW\r\n",
                .response = "-ERR syntax error\r\n",
            },
            .{
                .request = "*2\r\n$7\r\nCOMMAND\r\n$4\r\nDOCS\r\n",
                .response = "-ERR unsupported option\r\n",
            },
            .{
                .request = "*3\r\n$7\r\nCOMMAND\r\n$5\r\nCOUNT\r\n$5\r\nextra\r\n",
                .response = "-ERR wrong number of arguments\r\n",
            },
        };

        for (cases) |case| {
            try resp_client.sendAndExpect(io, server, fd, case.request, case.response);
            try resp_client.sendAndExpect(io, server, fd, "*1\r\n$4\r\nPING\r\n", "+PONG\r\n");
        }
        try resp_client.sendAndExpect(io, server, fd, "*2\r\n$3\r\nGET\r\n$3\r\nkey\r\n", "$8\r\noriginal\r\n");
    }

    try server.stop();
    std.log.info("integration: command error recovery passed", .{});
}
