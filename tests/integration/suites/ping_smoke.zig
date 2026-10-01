const std = @import("std");
const support = @import("server_process");

pub fn run(io: std.Io, allocator: std.mem.Allocator, executable_path: []const u8, artifact_dir: ?[]const u8) !void {
    std.log.info("integration: PING smoke test started", .{});
    const server = try support.ServerProcess.create(io, allocator, executable_path, .{ .artifact_dir = artifact_dir });
    defer server.destroy();
    errdefer server.failed = true;

    const client = try server.address.?.connect(io, .{ .mode = .stream });
    {
        defer client.close(io);
        const request = "*1\r\n$4\r\nPING\r\n";
        const written = try io.vtable.netWrite(io.userdata, client.socket.handle, request, &.{""}, 0);
        if (written != request.len) return error.ShortPingWrite;

        var reply: [7]u8 = undefined;
        try server.readExact(client.socket.handle, &reply);
        if (!std.mem.eql(u8, &reply, "+PONG\r\n")) return error.UnexpectedPingReply;
    }

    try server.stop();
    std.log.info("integration: PING smoke test passed", .{});
}
