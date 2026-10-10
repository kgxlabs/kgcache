const std = @import("std");
const support = @import("server_process");
const resp_client = @import("../harness/resp_client.zig");

const value_len = 16 * 1024 * 1024;
const ping = "*1\r\n$4\r\nPING\r\n";
const dbsize = "*1\r\n$6\r\nDBSIZE\r\n";
const get_then_del = "*2\r\n$3\r\nGET\r\n$5\r\nfruit\r\n*2\r\n$3\r\nDEL\r\n$5\r\nfruit\r\n";

pub fn run(io: std.Io, allocator: std.mem.Allocator, executable_path: []const u8, artifact_dir: ?[]const u8) !void {
    std.log.info("integration: slow reader, peer reset, and blocked writer shutdown started", .{});
    try checkTransport(io, allocator, executable_path, artifact_dir, false);
    try checkTransport(io, allocator, executable_path, artifact_dir, true);
    std.log.info("integration: slow reader, peer reset, and blocked writer shutdown passed", .{});
}

fn checkTransport(io: std.Io, allocator: std.mem.Allocator, executable_path: []const u8, artifact_dir: ?[]const u8, reset_peer: bool) !void {
    const server = try support.ServerProcess.createStopped(io, allocator, executable_path, .{
        .extra_config = "appendonly yes\nappendfsync always\nsave \"\"\n",
        .artifact_dir = artifact_dir,
    });
    defer server.destroy();
    errdefer server.failed = true;

    // Seed through AOF replay, whose limit profile permits a value larger than
    // a network request. One reply must exceed the socket's local send space.
    {
        var dir = try std.Io.Dir.cwd().openDir(io, server.data_dir, .{});
        defer dir.close(io);
        try dir.createDir(io, "aof", .default_dir);
        try dir.writeFile(io, .{
            .sub_path = "aof/appendonly.aof.manifest",
            .data = "file appendonly.aof.1.incr seq 1 type i\n",
        });
        var header_buffer: [64]u8 = undefined;
        const header = try std.fmt.bufPrint(&header_buffer, "*3\r\n$3\r\nSET\r\n$5\r\nfruit\r\n${d}\r\n", .{value_len});
        const seed = try allocator.alloc(u8, header.len + value_len + 2);
        defer allocator.free(seed);
        @memcpy(seed[0..header.len], header);
        @memset(seed[header.len..][0..value_len], 'x');
        @memcpy(seed[header.len + value_len ..], "\r\n");
        try dir.writeFile(io, .{ .sub_path = "aof/appendonly.aof.1.incr", .data = seed });
    }
    try server.start();

    const slow = try server.address.?.connect(io, .{ .mode = .stream });
    var slow_open = true;
    defer if (slow_open) slow.close(io);
    const receive_capacity: c_int = 4096;
    try std.posix.setsockopt(slow.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVBUF, std.mem.asBytes(&receive_capacity));
    const observer = try server.address.?.connect(io, .{ .mode = .stream });
    defer observer.close(io);

    var writer = slow.writer(io, &.{});
    try writer.interface.writeAll(get_then_del);
    try writer.interface.flush();
    var header_buffer: [32]u8 = undefined;
    const expected_header = try std.fmt.bufPrint(&header_buffer, "${d}\r\n", .{value_len});
    var reply_header: [32]u8 = undefined;
    try server.readExact(slow.socket.handle, reply_header[0..expected_header.len]);
    if (!std.mem.eql(u8, expected_header, reply_header[0..expected_header.len])) return error.UnexpectedReply;

    // Leave the body unread. The observer still gets storage and writes replies,
    // while the slow client's later DEL stays behind its unfinished GET reply.
    try resp_client.sendAndExpect(io, server, observer.socket.handle, ping, "+PONG\r\n");
    try resp_client.sendAndExpect(io, server, observer.socket.handle, dbsize, ":1\r\n");

    if (reset_peer) {
        try reset(io, slow);
        slow_open = false;
        try resp_client.sendAndExpect(io, server, observer.socket.handle, ping, "+PONG\r\n");
        try resp_client.sendAndExpect(io, server, observer.socket.handle, dbsize, ":1\r\n");

        // Also reset a session waiting for input after a completed reply.
        const idle = try server.address.?.connect(io, .{ .mode = .stream });
        var idle_open = true;
        defer if (idle_open) idle.close(io);
        try resp_client.sendAndExpect(io, server, idle.socket.handle, ping, "+PONG\r\n");
        try reset(io, idle);
        idle_open = false;
        try resp_client.sendAndExpect(io, server, observer.socket.handle, ping, "+PONG\r\n");
    }

    // Keep clients open through SIGTERM. The existing harness fails on a forced
    // kill or a nonzero exit, and requires shutdown within five seconds.
    try server.stop();
    if (std.mem.indexOf(u8, server.stdout.bytes(), "[error]") != null or
        std.mem.indexOf(u8, server.stderr.bytes(), "[error]") != null) return error.UnexpectedTransportErrorLog;
}

fn reset(io: std.Io, client: std.Io.net.Stream) !void {
    const linger: std.posix.linger = .{ .onoff = 1, .linger = 0 };
    try std.posix.setsockopt(client.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.LINGER, std.mem.asBytes(&linger));
    client.close(io);
}
