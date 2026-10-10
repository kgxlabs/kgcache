const std = @import("std");
const support = @import("server_process");
const resp_client = @import("../harness/resp_client.zig");

pub fn run(io: std.Io, allocator: std.mem.Allocator, executable_path: []const u8, artifact_dir: ?[]const u8) !void {
    std.log.info("integration: request limits started", .{});
    const server = try support.ServerProcess.create(io, allocator, executable_path, .{
        .artifact_dir = artifact_dir,
        .extra_config = "connection-buffer-size 128\n",
    });
    defer server.destroy();
    errdefer server.failed = true;

    {
        const observer = try server.address.?.connect(io, .{ .mode = .stream });
        defer observer.close(io);
        const prefix = "*3\r\n$3\r\nSET\r\n$5\r\nfruit\r\n$5\r\napple\r\n" ++
            "*2\r\n$3\r\nGET\r\n$5\r\nfruit\r\n";
        const headers = [_][]const u8{
            "*1025\r\n",
            "*3\r\n$3\r\nSET\r\n$5\r\nfruit\r\n$1048576\r\n",
        };

        for (headers) |header| {
            const client = try server.address.?.connect(io, .{ .mode = .stream });
            defer client.close(io);
            const request = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, header });
            defer allocator.free(request);

            try resp_client.sendAndExpect(io, server, client.socket.handle, request, "+OK\r\n$5\r\napple\r\n-ERR protocol error: request limit exceeded\r\n");

            var extra: [1]u8 = undefined;
            if (server.readExact(client.socket.handle, &extra)) |_| {
                return error.UnexpectedReplyAfterLimit;
            } else |err| {
                if (err != error.PrematureReplyEnd) return err;
            }

            try resp_client.sendAndExpect(io, server, observer.socket.handle, "*2\r\n$3\r\nGET\r\n$5\r\nfruit\r\n", "$5\r\napple\r\n");
        }
    }

    try server.stop();
    std.log.info("integration: request limits passed", .{});
}
