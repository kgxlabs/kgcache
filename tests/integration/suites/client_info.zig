const std = @import("std");
const support = @import("server_process");
const resp_client = @import("../harness/resp_client.zig");
const hello_metadata = @import("hello_metadata.zig");
const info_request = "*2\r\n$6\r\ncLiEnT\r\n$4\r\niNfO\r\n";
const ping_request = "*1\r\n$4\r\nPING\r\n";
const pong_reply = "+PONG\r\n";

pub fn run(io: std.Io, allocator: std.mem.Allocator, executable_path: []const u8, artifact_dir: ?[]const u8) !void {
    std.log.info("integration: CLIENT INFO binding and accounting started", .{});
    const server = try support.ServerProcess.create(io, allocator, executable_path, .{ .artifact_dir = artifact_dir });
    defer server.destroy();
    errdefer server.failed = true;

    {
        const client = try server.address.?.connect(io, .{ .mode = .stream });
        defer client.close(io);
        const cases = [_]struct { request: []const u8, response: []const u8, dispatches: u64 = 0 }{
            .{ .request = "*1\r\n$6\r\nCLIENT\r\n", .response = "-ERR wrong number of arguments\r\n" },
            .{ .request = "*3\r\n$6\r\ncLiEnT\r\n$4\r\niNfO\r\n$5\r\nextra\r\n", .response = "-ERR wrong number of arguments\r\n" },
            .{ .request = "*2\r\n$6\r\nCLIENT\r\n$7\r\nUNKNOWN\r\n", .response = "-ERR unsupported option\r\n" },
            .{ .request = "*2\r\n$6\r\nCLIENT\r\n$4\r\nLIST\r\n", .response = "-ERR unsupported option\r\n" },
            .{ .request = "*4\r\n$6\r\nCLIENT\r\n$4\r\nLIST\r\n$2\r\nID\r\n$1\r\n1\r\n", .response = "-ERR unsupported option\r\n" },
            .{ .request = "*4\r\n$6\r\nCLIENT\r\n$7\r\nSETINFO\r\n$8\r\nLIB-NAME\r\n$4\r\ntest\r\n", .response = "-ERR unsupported option\r\n" },
            .{ .request = "*1\r\n$7\r\nUNKNOWN\r\n", .response = "-ERR unknown command\r\n" },
            .{ .request = "*1\r\n$3\r\nGET\r\n", .response = "-ERR wrong number of arguments\r\n" },
            .{ .request = "*2\r\n$6\r\nSELECT\r\n$4\r\n9999\r\n", .response = "-ERR DB index is out of range\r\n", .dispatches = 1 },
            .{ .request = "*2\r\n$5\r\nHELLO\r\n$1\r\n4\r\n", .response = "-NOPROTO unsupported protocol version\r\n", .dispatches = 1 },
            .{ .request = "*3\r\n$5\r\nHELLO\r\n$1\r\n3\r\n$4\r\nAUTH\r\n", .response = "-ERR unsupported option\r\n", .dispatches = 1 },
        };
        var dispatches: u64 = 0;
        for ([_]u8{ 2, 3 }) |version| {
            var request_buffer: [512]u8 = undefined;
            var reply_buffer: [512]u8 = undefined;
            var metadata_buffer: [512]u8 = undefined;
            const db_index: u32 = version - 1;
            const metadata = try hello_metadata.expectedMetadata(&metadata_buffer, 1, version);
            const pipeline = try std.fmt.bufPrint(&request_buffer, "*2\r\n$5\r\nHELLO\r\n$1\r\n{d}\r\n" ++
                "*2\r\n$6\r\nSELECT\r\n$1\r\n{d}\r\n" ++
                "*3\r\n$5\r\nHELLO\r\n$1\r\n{d}\r\n$4\r\nAUTH\r\n" ++
                "*2\r\n$6\r\nSELECT\r\n$4\r\n9999\r\n" ++
                "*1\r\n$5\r\nHELLO\r\n{s}{s}", .{ version, db_index, @as(u8, if (version == 2) 3 else 2), info_request, ping_request });
            const previous_replies = try std.fmt.bufPrint(&reply_buffer, "{s}+OK\r\n-ERR unsupported option\r\n-ERR DB index is out of range\r\n{s}{s}", .{ metadata, metadata, if (version == 2) "$" else "=" });
            try resp_client.sendAndExpect(io, server, client.socket.handle, pipeline, previous_replies);
            const pipelined_info = try readInfo(server, client.socket.handle, 1, version, db_index);
            if (pipelined_info.commands != dispatches + 6) return error.UnexpectedDispatchAccounting;
            var pong: [pong_reply.len]u8 = undefined;
            try server.readExact(client.socket.handle, &pong);
            if (!std.mem.eql(u8, &pong, pong_reply)) return error.UnexpectedReply;
            dispatches += 7;
            for (cases) |case| {
                const request = try std.fmt.bufPrint(&request_buffer, "{s}*1\r\n$4\r\nPING\r\n", .{case.request});
                const response = try std.fmt.bufPrint(&reply_buffer, "{s}+PONG\r\n", .{case.response});
                try resp_client.sendAndExpect(io, server, client.socket.handle, request, response);
                dispatches += case.dispatches + 1;
            }
            const first = try expectInfo(io, server, client.socket.handle, 1, version, db_index);
            const second = try expectInfo(io, server, client.socket.handle, 1, version, db_index);
            if (first.commands != dispatches + 1 or second.commands != dispatches + 3) return error.UnexpectedDispatchAccounting;
            dispatches += 4;
            if (second.net_in - first.net_in != ping_request.len + info_request.len) return error.UnexpectedReadAccounting;
            if (second.net_out - first.net_out != first.reply_bytes + pong_reply.len) return error.UnexpectedWriteAccounting;
        }

        const second = try server.address.?.connect(io, .{ .mode = .stream });
        defer second.close(io);
        var metadata_buffer: [512]u8 = undefined;
        const metadata = try hello_metadata.expectedMetadata(&metadata_buffer, 2, 2);
        try resp_client.sendAndExpect(io, server, second.socket.handle, "*1\r\n$5\r\nHELLO\r\n", metadata);
        const report = try expectInfo(io, server, second.socket.handle, 2, 2, 0);
        if (report.commands != 2) return error.UnexpectedDispatchAccounting;
    }
    try server.stop();
    std.log.info("integration: CLIENT INFO binding and accounting passed", .{});
}

const InfoCounts = struct {
    net_in: u64 = 0,
    net_out: u64 = 0,
    commands: u64 = 0,
    reply_bytes: u64,
};

fn expectInfo(io: std.Io, server: *support.ServerProcess, fd: std.posix.fd_t, id: u64, version: u8, db_index: u32) !InfoCounts {
    try resp_client.sendAndExpect(io, server, fd, info_request, if (version == 2) "$" else "=");
    const counts = try readInfo(server, fd, id, version, db_index);
    try resp_client.sendAndExpect(io, server, fd, ping_request, pong_reply);
    return counts;
}

fn readInfo(server: *support.ServerProcess, fd: std.posix.fd_t, id: u64, version: u8, db_index: u32) !InfoCounts {
    var header: [24]u8 = undefined;
    var header_len: usize = 0;
    while (true) {
        if (header_len == header.len) return error.ReplyHeaderTooLong;
        try server.readExact(fd, header[header_len..][0..1]);
        if (header[header_len] == '\r') break;
        header_len += 1;
    }
    var lf: [1]u8 = undefined;
    try server.readExact(fd, &lf);
    if (lf[0] != '\n') return error.UnexpectedReply;
    const length = try std.fmt.parseInt(usize, header[0..header_len], 10);
    var counts: InfoCounts = .{ .reply_bytes = header_len + length + 5 };
    var buffer: [4096]u8 = undefined;
    if (length > buffer.len - 2) return error.ReplyTooLong;
    try server.readExact(fd, buffer[0 .. length + 2]);
    if (!std.mem.eql(u8, buffer[length..][0..2], "\r\n")) return error.UnexpectedReply;
    const text = if (version == 3) blk: {
        if (!std.mem.startsWith(u8, buffer[0..length], "txt:")) return error.UnexpectedReply;
        break :blk buffer[4..length];
    } else buffer[0..length];
    if (!std.mem.endsWith(u8, text, "\n")) return error.UnexpectedReply;
    const row = text[0 .. text.len - 1];
    if (std.mem.indexOfAny(u8, row, "\r\n") != null) return error.UnexpectedReply;
    const names = [_][]const u8{
        "id",   "addr",     "laddr",   "fd",         "age",         "idle",     "db",   "cmd",
        "resp", "lib-name", "lib-ver", "tot-net-in", "tot-net-out", "tot-cmds", "name", "sub",
        "psub", "ssub",     "watch",   "multi",      "multi-mem",   "redir",
    };
    var fields = std.mem.splitScalar(u8, row, ' ');
    for (names, 0..) |name, index| {
        const field = fields.next() orelse return error.UnexpectedReply;
        const equals = std.mem.indexOfScalar(u8, field, '=') orelse return error.UnexpectedReply;
        if (!std.mem.eql(u8, field[0..equals], name)) return error.UnexpectedReply;
        const value = field[equals + 1 ..];
        switch (index) {
            0 => if (try std.fmt.parseInt(u64, value, 10) != id) return error.UnexpectedReply,
            1 => {
                const address = try std.Io.net.IpAddress.parseLiteral(value);
                if (address.getPort() == 0) return error.UnexpectedReply;
            },
            2 => {
                const address = try std.Io.net.IpAddress.parseLiteral(value);
                if (!address.eql(&server.address.?)) return error.UnexpectedReply;
            },
            3, 4, 5 => _ = try std.fmt.parseInt(u64, value, 10),
            6 => if (try std.fmt.parseInt(u32, value, 10) != db_index) return error.UnexpectedDatabase,
            8 => if (try std.fmt.parseInt(u8, value, 10) != version) return error.UnexpectedProtocol,
            11 => counts.net_in = try std.fmt.parseInt(u64, value, 10),
            12 => counts.net_out = try std.fmt.parseInt(u64, value, 10),
            13 => counts.commands = try std.fmt.parseInt(u64, value, 10),
            7 => if (!std.mem.eql(u8, value, "client|info")) return error.UnexpectedReply,
            9, 10, 14 => if (value.len != 0) return error.UnexpectedReply,
            15, 16, 17, 18, 20 => if (!std.mem.eql(u8, value, "0")) return error.UnexpectedReply,
            19, 21 => if (!std.mem.eql(u8, value, "-1")) return error.UnexpectedReply,
            else => unreachable,
        }
    }
    if (fields.next() != null) return error.UnexpectedReply;
    return counts;
}
