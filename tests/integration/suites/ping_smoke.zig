const std = @import("std");
const support = @import("server_process");
const resp_client = @import("../harness/resp_client.zig");

pub fn run(io: std.Io, allocator: std.mem.Allocator, executable_path: []const u8, artifact_dir: ?[]const u8) !void {
    std.log.info("integration: PING message boundaries started", .{});
    const server = try support.ServerProcess.create(io, allocator, executable_path, .{ .artifact_dir = artifact_dir });
    defer server.destroy();
    errdefer server.failed = true;

    const client = try server.address.?.connect(io, .{ .mode = .stream });
    {
        defer client.close(io);
        const cases = [_]struct { request: []const u8, response: []const u8 }{
            .{
                .request = "*1\r\n$4\r\nPING\r\n",
                .response = "+PONG\r\n",
            },
            .{
                .request = "*2\r\n$4\r\nPING\r\n$5\r\nhello\r\n",
                .response = "$5\r\nhello\r\n",
            },
            .{
                .request = "*2\r\n$4\r\nPING\r\n$0\r\n\r\n",
                .response = "$0\r\n\r\n",
            },
            .{
                .request = "*2\r\n$4\r\nPING\r\n$6\r\na\x00\r\n\xffb\r\n",
                .response = "$6\r\na\x00\r\n\xffb\r\n",
            },
        };

        for (cases) |case| {
            try resp_client.sendAndExpect(io, server, client.socket.handle, case.request, case.response);
        }
        try resp_client.sendAndExpect(io, server, client.socket.handle, "*1\r\n$4\r\nPING\r\n", "+PONG\r\n");
    }

    try server.stop();
    std.log.info("integration: PING message boundaries passed", .{});
}
