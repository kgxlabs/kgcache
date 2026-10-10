const std = @import("std");
const build_options = @import("build_options");
const support = @import("server_process");
const resp_client = @import("../harness/resp_client.zig");

pub fn run(io: std.Io, allocator: std.mem.Allocator, executable_path: []const u8, artifact_dir: ?[]const u8) !void {
    std.log.info("integration: HELLO metadata started", .{});
    const server = try support.ServerProcess.create(io, allocator, executable_path, .{ .artifact_dir = artifact_dir });
    defer server.destroy();
    errdefer server.failed = true;

    {
        const first = try server.address.?.connect(io, .{ .mode = .stream });
        defer first.close(io);
        var first_buffer: [512]u8 = undefined;
        const first_reply = try expectedMetadata(&first_buffer, 1);
        try resp_client.sendAndExpect(io, server, first.socket.handle, "*1\r\n$5\r\nhElLo\r\n", first_reply);

        const second = try server.address.?.connect(io, .{ .mode = .stream });
        defer second.close(io);
        var second_buffer: [512]u8 = undefined;
        const second_reply = try expectedMetadata(&second_buffer, 2);
        try resp_client.sendAndExpect(io, server, second.socket.handle, "*1\r\n$5\r\nHELLO\r\n", second_reply);
        try resp_client.sendAndExpect(io, server, first.socket.handle, "*1\r\n$5\r\nhello\r\n", first_reply);

        try resp_client.sendAndExpect(
            io,
            server,
            first.socket.handle,
            "*2\r\n$5\r\nHELLO\r\n$1\r\n3\r\n*1\r\n$4\r\nPING\r\n",
            "-ERR unsupported option\r\n+PONG\r\n",
        );
        try resp_client.sendAndExpect(io, server, first.socket.handle, "*1\r\n$5\r\nHELLO\r\n", first_reply);
        try resp_client.sendAndExpect(
            io,
            server,
            first.socket.handle,
            "*3\r\n$7\r\nCOMMAND\r\n$4\r\nINFO\r\n$5\r\nHeLlO\r\n",
            "*1\r\n*10\r\n$5\r\nhello\r\n:-1\r\n*1\r\n$4\r\nfast\r\n:0\r\n:0\r\n:0\r\n" ++
                "*2\r\n$11\r\n@connection\r\n$5\r\n@fast\r\n*0\r\n*0\r\n*0\r\n",
        );
        try resp_client.sendAndExpect(io, server, first.socket.handle, "*2\r\n$7\r\nCOMMAND\r\n$5\r\nCOUNT\r\n", ":12\r\n");
    }

    try server.stop();
    std.log.info("integration: HELLO metadata passed", .{});
}

fn expectedMetadata(buffer: []u8, id: u64) ![]const u8 {
    return std.fmt.bufPrint(
        buffer,
        "*14\r\n$6\r\nserver\r\n$7\r\nkgcache\r\n$7\r\nversion\r\n${d}\r\n{s}\r\n" ++
            "$5\r\nproto\r\n:2\r\n$2\r\nid\r\n:{d}\r\n$4\r\nmode\r\n$10\r\nstandalone\r\n" ++
            "$4\r\nrole\r\n$6\r\nmaster\r\n$7\r\nmodules\r\n*0\r\n",
        .{ build_options.version.len, build_options.version, id },
    );
}
