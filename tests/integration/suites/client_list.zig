const std = @import("std");
const support = @import("server_process");
const resp_client = @import("../harness/resp_client.zig");
const hello_metadata = @import("hello_metadata.zig");

const list_request = "*2\r\n$6\r\ncLiEnT\r\n$4\r\nlIsT\r\n";
const ping_request = "*1\r\n$4\r\nPING\r\n";

pub fn run(io: std.Io, allocator: std.mem.Allocator, executable_path: []const u8, artifact_dir: ?[]const u8) !void {
    std.log.info("integration: CLIENT LIST live connections started", .{});
    for ([_]u8{ 2, 3 }) |version| try check(io, allocator, executable_path, artifact_dir, version);
    std.log.info("integration: CLIENT LIST live connections passed", .{});
}

fn check(io: std.Io, allocator: std.mem.Allocator, executable_path: []const u8, artifact_dir: ?[]const u8, version: u8) !void {
    const server = try support.ServerProcess.create(io, allocator, executable_path, .{ .artifact_dir = artifact_dir });
    defer server.destroy();
    errdefer server.failed = true;
    const caller = try server.address.?.connect(io, .{ .mode = .stream });
    defer caller.close(io);
    try hello(io, server, caller.socket.handle, 1, version);
    const peer = try server.address.?.connect(io, .{ .mode = .stream });
    var peer_open = true;
    defer if (peer_open) peer.close(io);
    try hello(io, server, peer.socket.handle, 2, version);
    try resp_client.sendAndExpect(io, server, caller.socket.handle, "*2\r\n$6\r\nSELECT\r\n$1\r\n1\r\n", "+OK\r\n");
    try resp_client.sendAndExpect(io, server, peer.socket.handle, "*2\r\n$6\r\nSELECT\r\n$1\r\n2\r\n", "+OK\r\n");
    try setInfo(io, server, caller.socket.handle, "LIB-NAME", "Caller");
    try setInfo(io, server, caller.socket.handle, "LIB-VER", "V1");
    try setInfo(io, server, peer.socket.handle, "LIB-NAME", "Peer");
    try setInfo(io, server, peer.socket.handle, "LIB-VER", "V2");
    try resp_client.sendAndExpect(io, server, peer.socket.handle, ping_request, "+PONG\r\n");
    var caller_commands: u64 = 4;

    {
        var reports = try list(io, server, caller.socket.handle, allocator, version);
        defer reports.deinit();
        caller_commands += 1;
        if (reports.rows.len != 2) return error.UnexpectedLiveConnections;
        try expectRow(reports.rows[0], 1, 1, version, "client|list", "Caller", "V1", caller_commands);
        try expectRow(reports.rows[1], 2, 2, version, "ping", "Peer", "V2", 5);
        if (std.mem.eql(u8, reports.rows[0].values[1], reports.rows[1].values[1])) return error.UnexpectedEndpoints;
        const local = try std.Io.net.IpAddress.parseLiteral(reports.rows[0].values[2]);
        if (!local.eql(&server.address.?)) return error.UnexpectedEndpoints;
    }
    try setInfo(io, server, peer.socket.handle, "LIB-NAME", "Replacement");
    try setInfo(io, server, peer.socket.handle, "LIB-VER", "");
    {
        var reports = try list(io, server, caller.socket.handle, allocator, version);
        defer reports.deinit();
        caller_commands += 1;
        if (reports.rows.len != 2) return error.UnexpectedLiveConnections;
        try expectRow(reports.rows[1], 2, 2, version, "client|setinfo", "Replacement", "", 7);
    }

    const selected: u8 = if (version == 2) 3 else 2;
    {
        var request_buffer: [512]u8 = undefined;
        var metadata_buffer: [512]u8 = undefined;
        var reply_buffer: [1024]u8 = undefined;
        const request = try std.fmt.bufPrint(&request_buffer, "*2\r\n$5\r\nHELLO\r\n$1\r\n{d}\r\n" ++
            "*2\r\n$6\r\nSELECT\r\n$1\r\n3\r\n" ++
            "*4\r\n$6\r\nCLIENT\r\n$7\r\nSETINFO\r\n$8\r\nLIB-NAME\r\n$7\r\nUpdated\r\n{s}{s}", .{ selected, list_request, ping_request });
        const metadata = try hello_metadata.expectedMetadata(&metadata_buffer, 1, selected);
        const prefix = try std.fmt.bufPrint(&reply_buffer, "{s}+OK\r\n+OK\r\n", .{metadata});
        try resp_client.sendAndExpect(io, server, caller.socket.handle, request, prefix);
        var reports = try readReports(server, caller.socket.handle, allocator, selected);
        defer reports.deinit();
        caller_commands += 4;
        if (reports.rows.len != 2) return error.UnexpectedLiveConnections;
        try expectRow(reports.rows[0], 1, 3, selected, "client|list", "Updated", "V1", caller_commands);
        try expectRow(reports.rows[1], 2, 2, version, "client|setinfo", "Replacement", "", 7);
        var pong: [7]u8 = undefined;
        try server.readExact(caller.socket.handle, &pong);
        if (!std.mem.eql(u8, &pong, "+PONG\r\n")) return error.UnexpectedReply;
        caller_commands += 1;
    }

    for ([_][]const u8{
        "*4\r\n$6\r\nCLIENT\r\n$4\r\nLIST\r\n$2\r\nID\r\n$1\r\n2\r\n",
        "*4\r\n$6\r\nCLIENT\r\n$4\r\nLIST\r\n$4\r\nTYPE\r\n$6\r\nNORMAL\r\n",
    }) |invalid| {
        var request_buffer: [256]u8 = undefined;
        const pipeline = try std.fmt.bufPrint(&request_buffer, "{s}{s}{s}", .{ invalid, ping_request, list_request });
        try resp_client.sendAndExpect(io, server, caller.socket.handle, pipeline, "-ERR wrong number of arguments\r\n+PONG\r\n");
        var reports = try readReports(server, caller.socket.handle, allocator, selected);
        defer reports.deinit();
        caller_commands += 2;
        try expectRow(reports.rows[0], 1, 3, selected, "client|list", "Updated", "V1", caller_commands);
    }

    peer.close(io);
    peer_open = false;
    const deadline = std.Io.Clock.awake.now(io).nanoseconds + 3 * std.time.ns_per_s;
    while (true) {
        var reports = try list(io, server, caller.socket.handle, allocator, selected);
        defer reports.deinit();
        caller_commands += 1;
        try expectRow(reports.rows[0], 1, 3, selected, "client|list", "Updated", "V1", caller_commands);
        if (reports.rows.len == 1) break;
        if (std.Io.Clock.awake.now(io).nanoseconds >= deadline) return error.FinishedConnectionStillVisible;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    const reconnected = try server.address.?.connect(io, .{ .mode = .stream });
    defer reconnected.close(io);
    try hello(io, server, reconnected.socket.handle, 3, version);
    {
        var reports = try list(io, server, caller.socket.handle, allocator, selected);
        defer reports.deinit();
        caller_commands += 1;
        if (reports.rows.len != 2) return error.UnexpectedLiveConnections;
        try expectRow(reports.rows[0], 1, 3, selected, "client|list", "Updated", "V1", caller_commands);
        try expectRow(reports.rows[1], 3, 0, version, "hello", "", "", 1);
    }
    try resp_client.sendAndExpect(io, server, caller.socket.handle, ping_request, "+PONG\r\n");
    try server.stop();
    if (std.mem.indexOf(u8, server.stdout.bytes(), "[error]") != null or
        std.mem.indexOf(u8, server.stderr.bytes(), "[error]") != null) return error.UnexpectedReportErrorLog;
}

fn hello(io: std.Io, server: *support.ServerProcess, fd: std.posix.fd_t, id: u64, version: u8) !void {
    var request_buffer: [64]u8 = undefined;
    var metadata_buffer: [512]u8 = undefined;
    const request = try std.fmt.bufPrint(&request_buffer, "*2\r\n$5\r\nHELLO\r\n$1\r\n{d}\r\n", .{version});
    const metadata = try hello_metadata.expectedMetadata(&metadata_buffer, id, version);
    try resp_client.sendAndExpect(io, server, fd, request, metadata);
}

fn setInfo(io: std.Io, server: *support.ServerProcess, fd: std.posix.fd_t, attribute: []const u8, value: []const u8) !void {
    var buffer: [512]u8 = undefined;
    const request = try std.fmt.bufPrint(&buffer, "*4\r\n$6\r\nCLIENT\r\n$7\r\nSETINFO\r\n${d}\r\n{s}\r\n${d}\r\n{s}\r\n", .{ attribute.len, attribute, value.len, value });
    try resp_client.sendAndExpect(io, server, fd, request, "+OK\r\n");
}

const Row = struct {
    values: [22][]const u8,
};

const Reports = struct {
    payload: []u8,
    rows: []Row,
    allocator: std.mem.Allocator,

    fn deinit(self: *Reports) void {
        self.allocator.free(self.rows);
        self.allocator.free(self.payload);
    }
};

fn list(io: std.Io, server: *support.ServerProcess, fd: std.posix.fd_t, allocator: std.mem.Allocator, version: u8) !Reports {
    try resp_client.sendAndExpect(io, server, fd, list_request, "");
    return readReports(server, fd, allocator, version);
}

fn readReports(server: *support.ServerProcess, fd: std.posix.fd_t, allocator: std.mem.Allocator, version: u8) !Reports {
    var marker: [1]u8 = undefined;
    try server.readExact(fd, &marker);
    if (marker[0] != (if (version == 2) @as(u8, '$') else '=')) return error.UnexpectedReportEncoding;
    var header: [32]u8 = undefined;
    var header_len: usize = 0;
    while (true) {
        if (header_len == header.len) return error.ReplyHeaderTooLong;
        try server.readExact(fd, header[header_len..][0..1]);
        if (header[header_len] == '\r') break;
        header_len += 1;
    }
    try server.readExact(fd, &marker);
    if (marker[0] != '\n') return error.UnexpectedReply;
    const length = try std.fmt.parseInt(usize, header[0..header_len], 10);
    if (length > 16 * 1024 * 1024) return error.ReplyTooLong;
    const payload = try allocator.alloc(u8, length);
    errdefer allocator.free(payload);
    try server.readExact(fd, payload);
    var terminator: [2]u8 = undefined;
    try server.readExact(fd, &terminator);
    if (!std.mem.eql(u8, &terminator, "\r\n")) return error.UnexpectedReply;
    const text = if (version == 3) blk: {
        if (!std.mem.startsWith(u8, payload, "txt:")) return error.UnexpectedReply;
        break :blk payload[4..];
    } else payload;
    if (text.len != 0 and !std.mem.endsWith(u8, text, "\n")) return error.UnexpectedReply;
    var rows: std.ArrayList(Row) = .empty;
    defer rows.deinit(allocator);
    var lines = std.mem.splitScalar(u8, text, '\n');
    var previous_id: u64 = 0;
    while (lines.next()) |line| {
        if (line.len == 0) {
            if (lines.next() != null) return error.UnexpectedReply;
            break;
        }
        const row = try parseRow(line);
        const id = try std.fmt.parseInt(u64, row.values[0], 10);
        if (id <= previous_id) return error.UnsortedConnectionIds;
        previous_id = id;
        try rows.append(allocator, row);
    }
    return .{ .payload = payload, .rows = try rows.toOwnedSlice(allocator), .allocator = allocator };
}

fn parseRow(line: []const u8) !Row {
    const names = [_][]const u8{
        "id",   "addr",     "laddr",   "fd",         "age",         "idle",     "db",   "cmd",
        "resp", "lib-name", "lib-ver", "tot-net-in", "tot-net-out", "tot-cmds", "name", "sub",
        "psub", "ssub",     "watch",   "multi",      "multi-mem",   "redir",
    };
    var row: Row = undefined;
    var fields = std.mem.splitScalar(u8, line, ' ');
    for (names, 0..) |name, index| {
        const field = fields.next() orelse return error.UnexpectedReply;
        const equals = std.mem.indexOfScalar(u8, field, '=') orelse return error.UnexpectedReply;
        if (!std.mem.eql(u8, field[0..equals], name)) return error.UnexpectedReply;
        const value = field[equals + 1 ..];
        row.values[index] = value;
        switch (index) {
            0, 3, 4, 5, 6, 8, 11, 12, 13 => _ = try std.fmt.parseInt(u64, value, 10),
            1, 2 => {
                const endpoint = try std.Io.net.IpAddress.parseLiteral(value);
                if (endpoint.getPort() == 0) return error.UnexpectedEndpoints;
            },
            7 => if (value.len == 0) return error.UnexpectedReply,
            9, 10 => for (value) |byte| {
                if (byte < '!' or byte > '~') return error.UnexpectedLibraryInfo;
            },
            14 => if (value.len != 0) return error.UnexpectedReply,
            15, 16, 17, 18, 20 => if (!std.mem.eql(u8, value, "0")) return error.UnexpectedReply,
            19, 21 => if (!std.mem.eql(u8, value, "-1")) return error.UnexpectedReply,
            else => unreachable,
        }
    }
    if (fields.next() != null) return error.UnexpectedReply;
    return row;
}

fn expectRow(row: Row, id: u64, db: u32, version: u8, command: []const u8, library_name: []const u8, library_version: []const u8, commands: u64) !void {
    if (try std.fmt.parseInt(u64, row.values[0], 10) != id) return error.UnexpectedConnectionId;
    if (try std.fmt.parseInt(u32, row.values[6], 10) != db) return error.UnexpectedDatabase;
    if (try std.fmt.parseInt(u8, row.values[8], 10) != version) return error.UnexpectedProtocol;
    if (!std.mem.eql(u8, row.values[7], command)) return error.UnexpectedCanonicalName;
    if (!std.mem.eql(u8, row.values[9], library_name)) return error.UnexpectedLibraryInfo;
    if (!std.mem.eql(u8, row.values[10], library_version)) return error.UnexpectedLibraryInfo;
    if (try std.fmt.parseInt(u64, row.values[13], 10) != commands) return error.UnexpectedDispatchAccounting;
}
