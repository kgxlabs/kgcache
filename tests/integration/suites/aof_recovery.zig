const std = @import("std");
const support = @import("server_process");
const resp_client = @import("../harness/resp_client.zig");

const select_1 = "*2\r\n$6\r\nSELECT\r\n$1\r\n1\r\n";
const good = select_1 ++
    "*3\r\n$3\r\nSET\r\n$6\r\nstable\r\n$5\r\nvalue\r\n" ++
    "*3\r\n$3\r\nSET\r\n$0\r\n\r\n$3\r\n\x00\r\n\r\n";
const unfinished = "*3\r\n$3\r\nSET\r\n$3\r\nbad\r\n$5\r\npar";
const malformed = "*3\r\n$3\r\nDEL\r\n$6\r\nstable\r\n$1\r\nxX";
const final_path = "aof/appendonly.aof.1.incr";

pub fn run(io: std.Io, allocator: std.mem.Allocator, executable_path: []const u8, artifact_dir: ?[]const u8) !void {
    std.log.info("integration: AOF recovery started", .{});
    try checkRecovery(io, allocator, executable_path, artifact_dir);
    const rejected = [_]struct { contents: []const u8, recover: bool, source: []const u8 }{
        .{ .contents = good ++ unfinished, .recover = false, .source = "TruncatedAof" },
        .{ .contents = good ++ malformed, .recover = true, .source = "InvalidBulkTerminator" },
        .{ .contents = good ++ malformed ++ good, .recover = true, .source = "InvalidBulkTerminator" },
    };
    for (rejected) |case| {
        try checkRejected(io, allocator, executable_path, artifact_dir, case.contents, case.recover, case.source);
    }
    std.log.info("integration: AOF recovery passed", .{});
}

fn prepare(io: std.Io, dir: std.Io.Dir, contents: []const u8) !void {
    try dir.createDir(io, "aof", .default_dir);
    try dir.writeFile(io, .{
        .sub_path = "aof/appendonly.aof.manifest",
        .data = "file appendonly.aof.1.incr seq 1 type i\n",
    });
    try dir.writeFile(io, .{ .sub_path = final_path, .data = contents });
}

fn expectFile(io: std.Io, allocator: std.mem.Allocator, dir: std.Io.Dir, expected: []const u8) !void {
    const contents = try dir.readFileAlloc(io, final_path, allocator, .unlimited);
    defer allocator.free(contents);
    if (!std.mem.eql(u8, expected, contents)) return error.UnexpectedAofBytes;
}

fn checkRecovery(io: std.Io, allocator: std.mem.Allocator, executable_path: []const u8, artifact_dir: ?[]const u8) !void {
    const server = try support.ServerProcess.createStopped(io, allocator, executable_path, .{
        .extra_config = "appendonly yes\nappendfsync always\naof-load-truncated yes\ndatabases 2\nsave \"\"\n",
        .artifact_dir = artifact_dir,
    });
    defer server.destroy();
    errdefer server.failed = true;
    var dir = try std.Io.Dir.cwd().openDir(io, server.data_dir, .{});
    defer dir.close(io);
    try prepare(io, dir, good ++ unfinished);
    try server.start();
    try expectFile(io, allocator, dir, good);

    {
        const client = try server.address.?.connect(io, .{ .mode = .stream });
        defer client.close(io);
        const fd = client.socket.handle;
        try resp_client.sendAndExpect(io, server, fd, "*2\r\n$3\r\nGET\r\n$6\r\nstable\r\n", "$-1\r\n");
        try resp_client.sendAndExpect(io, server, fd, select_1, "+OK\r\n");
        try resp_client.sendAndExpect(io, server, fd, "*2\r\n$3\r\nGET\r\n$6\r\nstable\r\n", "$5\r\nvalue\r\n");
        try resp_client.sendAndExpect(io, server, fd, "*2\r\n$3\r\nGET\r\n$0\r\n\r\n", "$3\r\n\x00\r\n\r\n");
        try resp_client.sendAndExpect(io, server, fd, "*2\r\n$3\r\nGET\r\n$3\r\nbad\r\n", "$-1\r\n");
        try resp_client.sendAndExpect(io, server, fd, "*4\r\n$3\r\nSET\r\n$6\r\nstable\r\n$7\r\nblocked\r\n$2\r\nNX\r\n", "$-1\r\n");
        try resp_client.sendAndExpect(io, server, fd, "*4\r\n$3\r\nSET\r\n$7\r\nmissing\r\n$7\r\nblocked\r\n$2\r\nXX\r\n", "$-1\r\n");
        try expectFile(io, allocator, dir, good);
        try resp_client.sendAndExpect(io, server, fd, "*3\r\n$3\r\nDEL\r\n$6\r\nstable\r\n$0\r\n\r\n", ":2\r\n");
        try expectFile(io, allocator, dir, good ++ select_1 ++
            "*2\r\n$3\r\nDEL\r\n$6\r\nstable\r\n" ++
            "*2\r\n$3\r\nDEL\r\n$0\r\n\r\n");
        try resp_client.sendAndExpect(io, server, fd, "*3\r\n$3\r\nSET\r\n$5\r\nafter\r\n$8\r\nwritable\r\n", "+OK\r\n");
    }
    try server.stop();
    var buffer: [128]u8 = undefined;
    const warning = try std.fmt.bufPrint(&buffer, "AOF recovery: truncated unfinished tail at offset {d}, discarded {d} bytes", .{ good.len, unfinished.len });
    if (std.mem.count(u8, server.stdout.bytes(), warning) + std.mem.count(u8, server.stderr.bytes(), warning) != 1) return error.MissingRecoveryWarning;

    const before_restart = try dir.readFileAlloc(io, final_path, allocator, .unlimited);
    defer allocator.free(before_restart);
    try server.start();
    try expectFile(io, allocator, dir, before_restart);
    {
        const client = try server.address.?.connect(io, .{ .mode = .stream });
        defer client.close(io);
        const fd = client.socket.handle;
        try resp_client.sendAndExpect(io, server, fd, select_1, "+OK\r\n");
        try resp_client.sendAndExpect(io, server, fd, "*2\r\n$3\r\nGET\r\n$5\r\nafter\r\n", "$8\r\nwritable\r\n");
        try resp_client.sendAndExpect(io, server, fd, "*2\r\n$3\r\nGET\r\n$6\r\nstable\r\n", "$-1\r\n");
        try resp_client.sendAndExpect(io, server, fd, "*2\r\n$3\r\nGET\r\n$0\r\n\r\n", "$-1\r\n");
        try resp_client.sendAndExpect(io, server, fd, "*2\r\n$3\r\nGET\r\n$3\r\nbad\r\n", "$-1\r\n");
    }
    try server.stop();
    if (std.mem.count(u8, server.stdout.bytes(), "AOF recovery:") + std.mem.count(u8, server.stderr.bytes(), "AOF recovery:") != 0) return error.UnexpectedRecoveryWarning;
}

fn checkRejected(io: std.Io, allocator: std.mem.Allocator, executable_path: []const u8, artifact_dir: ?[]const u8, contents: []const u8, recover: bool, source: []const u8) !void {
    const server = try support.ServerProcess.createStopped(io, allocator, executable_path, .{
        .extra_config = if (recover)
            "appendonly yes\naof-load-truncated yes\ndatabases 2\nsave \"\"\n"
        else
            "appendonly yes\naof-load-truncated no\ndatabases 2\nsave \"\"\n",
        .artifact_dir = artifact_dir,
        .report_failures = false,
    });
    defer server.destroy();
    errdefer {
        server.failed = true;
        std.log.err("integration: AOF rejection failed; stdout: {s}; stderr: {s}", .{ server.stdout.bytes(), server.stderr.bytes() });
    }
    var dir = try std.Io.Dir.cwd().openDir(io, server.data_dir, .{});
    defer dir.close(io);
    try prepare(io, dir, contents);
    server.start() catch |err| {
        if (err != error.StartupExited) return err;
        const status = server.last_exit_status orelse return error.MissingExitStatus;
        if (!std.c.W.IFEXITED(status) or std.c.W.EXITSTATUS(status) != 1) return error.WrongExitStatus;
        if (server.ready_bytes_read != 0) return error.UnexpectedReadyOutput;
        if (std.mem.indexOf(u8, server.stdout.bytes(), source) == null and std.mem.indexOf(u8, server.stderr.bytes(), source) == null) return error.WrongStartupError;
        if (std.mem.count(u8, server.stdout.bytes(), "AOF recovery:") + std.mem.count(u8, server.stderr.bytes(), "AOF recovery:") != 0) return error.UnexpectedRecoveryWarning;
        try expectFile(io, allocator, dir, contents);
        server.failed = false;
        return;
    };
    return error.ExpectedStartupFailure;
}
