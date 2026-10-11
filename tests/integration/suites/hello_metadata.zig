const std = @import("std");
const build_options = @import("build_options");
const support = @import("server_process");
const resp_client = @import("../harness/resp_client.zig");

pub fn run(io: std.Io, allocator: std.mem.Allocator, executable_path: []const u8, artifact_dir: ?[]const u8) !void {
    std.log.info("integration: HELLO negotiation started", .{});
    const server = try support.ServerProcess.create(io, allocator, executable_path, .{ .artifact_dir = artifact_dir });
    defer server.destroy();
    errdefer server.failed = true;

    {
        const first = try server.address.?.connect(io, .{ .mode = .stream });
        defer first.close(io);
        var first_buffer: [512]u8 = undefined;
        const first_reply = try expectedMetadata(&first_buffer, 1, 2);
        try resp_client.sendAndExpect(io, server, first.socket.handle, "*1\r\n$5\r\nhElLo\r\n", first_reply);

        const second = try server.address.?.connect(io, .{ .mode = .stream });
        defer second.close(io);
        var second_buffer: [512]u8 = undefined;
        const second_reply = try expectedMetadata(&second_buffer, 2, 2);
        try resp_client.sendAndExpect(io, server, second.socket.handle, "*1\r\n$5\r\nHELLO\r\n", second_reply);
        try resp_client.sendAndExpect(io, server, first.socket.handle, "*1\r\n$5\r\nhello\r\n", first_reply);

        const invalid_requests = [_]struct { request: []const u8, reply: []const u8 }{
            .{ .request = "*2\r\n$5\r\nHELLO\r\n$1\r\n4\r\n", .reply = "-NOPROTO unsupported protocol version\r\n" },
            .{ .request = "*2\r\n$5\r\nHELLO\r\n$1\r\nx\r\n", .reply = "-ERR malformed command request\r\n" },
            .{ .request = "*5\r\n$5\r\nHELLO\r\n$1\r\n2\r\n$4\r\nAUTH\r\n$4\r\nuser\r\n$8\r\npassword\r\n", .reply = "-ERR unsupported option\r\n" },
            .{ .request = "*4\r\n$5\r\nHELLO\r\n$1\r\n3\r\n$7\r\nSETNAME\r\n$4\r\nname\r\n", .reply = "-ERR unsupported option\r\n" },
            .{ .request = "*3\r\n$5\r\nHELLO\r\n$1\r\n3\r\n$1\r\n2\r\n", .reply = "-ERR unsupported option\r\n" },
        };
        const get_missing = "*2\r\n$3\r\nGET\r\n$7\r\nmissing\r\n";
        const bare_hello = "*1\r\n$5\r\nhello\r\n";
        for ([_]u8{ 3, 2 }) |version| {
            var metadata_buffer: [512]u8 = undefined;
            const metadata = try expectedMetadata(&metadata_buffer, 1, version);
            const missing_reply = if (version == 2) "$-1\r\n" else "_\r\n";
            var request_buffer: [512]u8 = undefined;
            const request = try std.fmt.bufPrint(&request_buffer, "*2\r\n$5\r\nhElLo\r\n$1\r\n{d}\r\n{s}{s}", .{ version, get_missing, bare_hello });
            var reply_buffer: [2048]u8 = undefined;
            const reply = try std.fmt.bufPrint(&reply_buffer, "{s}{s}{s}", .{ metadata, missing_reply, metadata });
            try resp_client.sendAndExpect(io, server, first.socket.handle, request, reply);

            for (invalid_requests) |invalid| {
                const invalid_pipeline = try std.fmt.bufPrint(&request_buffer, "{s}{s}{s}", .{ invalid.request, get_missing, bare_hello });
                const unchanged_reply = try std.fmt.bufPrint(&reply_buffer, "{s}{s}{s}", .{ invalid.reply, missing_reply, metadata });
                try resp_client.sendAndExpect(io, server, first.socket.handle, invalid_pipeline, unchanged_reply);
            }

            try resp_client.sendAndExpect(io, server, second.socket.handle, get_missing, "$-1\r\n");
            try resp_client.sendAndExpect(io, server, second.socket.handle, bare_hello, second_reply);
        }
        try resp_client.sendAndExpect(
            io,
            server,
            first.socket.handle,
            "*3\r\n$7\r\nCOMMAND\r\n$4\r\nINFO\r\n$5\r\nHeLlO\r\n",
            "*1\r\n*10\r\n$5\r\nhello\r\n:-1\r\n*1\r\n$4\r\nfast\r\n:0\r\n:0\r\n:0\r\n" ++
                "*2\r\n$11\r\n@connection\r\n$5\r\n@fast\r\n*0\r\n*0\r\n*0\r\n",
        );
        try resp_client.sendAndExpect(io, server, first.socket.handle, "*2\r\n$7\r\nCOMMAND\r\n$5\r\nCOUNT\r\n", ":13\r\n");
    }

    try server.stop();
    std.log.info("integration: HELLO negotiation passed", .{});
}

pub fn expectedMetadata(buffer: []u8, id: u64, version: u8) ![]const u8 {
    return std.fmt.bufPrint(
        buffer,
        "{s}$6\r\nserver\r\n$7\r\nkgcache\r\n$7\r\nversion\r\n${d}\r\n{s}\r\n" ++
            "$5\r\nproto\r\n:{d}\r\n$2\r\nid\r\n:{d}\r\n$4\r\nmode\r\n$10\r\nstandalone\r\n" ++
            "$4\r\nrole\r\n$6\r\nmaster\r\n$7\r\nmodules\r\n*0\r\n",
        .{ if (version == 2) "*14\r\n" else "%7\r\n", build_options.version.len, build_options.version, version, id },
    );
}
