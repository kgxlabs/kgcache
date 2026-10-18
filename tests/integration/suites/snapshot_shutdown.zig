const std = @import("std");
const support = @import("server_process");
const resp_client = @import("../harness/resp_client.zig");

pub fn run(io: std.Io, allocator: std.mem.Allocator, executable_path: []const u8, artifact_dir: ?[]const u8) !void {
    std.log.info("integration: final shutdown snapshot started", .{});
    const cases = [_]struct {
        config: []const u8,
        args: []const []const u8 = &.{},
        saved: bool = true,
        previous_snapshot: bool = false,
        signal: std.posix.SIG = .TERM,
    }{
        .{ .config = "save 3600 1\n" },
        .{ .config = "save 3600 1\n", .signal = .INT },
        .{ .config = "save \"\"\n" },
        .{ .config = "save \"\"\n", .previous_snapshot = true },
        .{ .config = "save \"\"\nshutdown-save no\n", .saved = false, .previous_snapshot = true },
        .{ .config = "save \"\"\nshutdown-save no\n", .args = &.{ "--shutdown-save", "yes" } },
        .{ .config = "save \"\"\nshutdown-save yes\n", .args = &.{ "--shutdown-save", "no" }, .saved = false },
    };
    for (cases) |case| {
        const config = try std.fmt.allocPrint(allocator, "appendonly no\ndbfilename state.kgc\n{s}", .{case.config});
        defer allocator.free(config);
        const server = try support.ServerProcess.create(io, allocator, executable_path, .{
            .extra_config = config,
            .extra_args = case.args,
            .artifact_dir = artifact_dir,
        });
        defer server.destroy();
        errdefer server.failed = true;
        var dir = try std.Io.Dir.cwd().openDir(io, server.data_dir, .{});
        defer dir.close(io);
        var previous_file: ?std.Io.File = null;
        defer if (previous_file) |file| file.close(io);
        {
            const client = try server.address.?.connect(io, .{ .mode = .stream });
            defer client.close(io);
            const fd = client.socket.handle;
            if (case.previous_snapshot) {
                try resp_client.sendAndExpect(io, server, fd, "*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$3\r\nold\r\n", "+OK\r\n");
                try resp_client.sendAndExpect(io, server, fd, "*1\r\n$4\r\nSAVE\r\n", "+OK\r\n");
                if (!case.saved) previous_file = try dir.openFile(io, "state.kgc", .{});
            }
            try resp_client.sendAndExpect(io, server, fd, "*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$5\r\nfresh\r\n", "+OK\r\n");
        }
        try server.stopWithSignal(case.signal);
        if (previous_file) |file| try expectSameSnapshot(io, dir, file);
        try server.start();
        {
            const client = try server.address.?.connect(io, .{ .mode = .stream });
            defer client.close(io);
            const expected = if (case.saved) "$5\r\nfresh\r\n" else if (case.previous_snapshot) "$3\r\nold\r\n" else "$-1\r\n";
            try resp_client.sendAndExpect(io, server, client.socket.handle, "*2\r\n$3\r\nGET\r\n$3\r\nkey\r\n", expected);
        }
        try server.stop();
    }
    try checkEmptyDatabase(io, allocator, executable_path, artifact_dir);
    try checkSnapshotContents(io, allocator, executable_path, artifact_dir);
    std.log.info("integration: final shutdown snapshot passed", .{});
}

fn expectSameSnapshot(io: std.Io, dir: std.Io.Dir, original: std.Io.File) !void {
    const before = try original.stat(io);
    const after = try dir.statFile(io, "state.kgc", .{});
    if (before.inode != after.inode) return error.UnexpectedSnapshotReplacement;
}

fn checkEmptyDatabase(io: std.Io, allocator: std.mem.Allocator, executable_path: []const u8, artifact_dir: ?[]const u8) !void {
    const server = try support.ServerProcess.create(io, allocator, executable_path, .{
        .extra_config = "appendonly no\nsave \"\"\ndbfilename state.kgc\n",
        .artifact_dir = artifact_dir,
    });
    defer server.destroy();
    errdefer server.failed = true;
    var dir = try std.Io.Dir.cwd().openDir(io, server.data_dir, .{});
    defer dir.close(io);

    try server.stop();
    if (dir.access(io, "state.kgc", .{})) |_| {
        return error.UnexpectedSnapshot;
    } else |err| {
        if (err != error.FileNotFound) return err;
    }

    try server.start();
    {
        const client = try server.address.?.connect(io, .{ .mode = .stream });
        defer client.close(io);
        const fd = client.socket.handle;
        try resp_client.sendAndExpect(io, server, fd, "*3\r\n$3\r\nSET\r\n$4\r\nlast\r\n$5\r\nvalue\r\n", "+OK\r\n");
        try resp_client.sendAndExpect(io, server, fd, "*1\r\n$4\r\nSAVE\r\n", "+OK\r\n");
        try resp_client.sendAndExpect(io, server, fd, "*2\r\n$3\r\nDEL\r\n$4\r\nlast\r\n", ":1\r\n");
    }
    try server.stop();
    try dir.access(io, "state.kgc", .{});
    try server.start();
    {
        const client = try server.address.?.connect(io, .{ .mode = .stream });
        defer client.close(io);
        try resp_client.sendAndExpect(io, server, client.socket.handle, "*1\r\n$6\r\nDBSIZE\r\n", ":0\r\n");
    }
    try server.stop();
}

fn checkSnapshotContents(io: std.Io, allocator: std.mem.Allocator, executable_path: []const u8, artifact_dir: ?[]const u8) !void {
    const server = try support.ServerProcess.create(io, allocator, executable_path, .{
        .extra_config = "appendonly no\nsave \"\"\ndbfilename state.kgc\ndatabases 2\n",
        .artifact_dir = artifact_dir,
    });
    defer server.destroy();
    errdefer server.failed = true;
    var dir = try std.Io.Dir.cwd().openDir(io, server.data_dir, .{});
    defer dir.close(io);
    const select_1 = "*2\r\n$6\r\nSELECT\r\n$1\r\n1\r\n";
    const binary_get = "*2\r\n$3\r\nGET\r\n$3\r\n\x00\r\n\r\n";
    const expires_ms = std.Io.Clock.real.now(io).toMilliseconds() + 5_000;
    {
        const client = try server.address.?.connect(io, .{ .mode = .stream });
        defer client.close(io);
        const fd = client.socket.handle;
        try resp_client.sendAndExpect(io, server, fd, "*3\r\n$3\r\nSET\r\n$6\r\nshared\r\n$3\r\nold\r\n", "+OK\r\n");
        try resp_client.sendAndExpect(io, server, fd, "*3\r\n$3\r\nSET\r\n$7\r\nremoved\r\n$3\r\nold\r\n", "+OK\r\n");
        try resp_client.sendAndExpect(io, server, fd, "*1\r\n$4\r\nSAVE\r\n", "+OK\r\n");
        try resp_client.sendAndExpect(io, server, fd, "*3\r\n$3\r\nSET\r\n$6\r\nshared\r\n$3\r\nnew\r\n", "+OK\r\n");
        try resp_client.sendAndExpect(io, server, fd, "*2\r\n$3\r\nDEL\r\n$7\r\nremoved\r\n", ":1\r\n");
        try resp_client.sendAndExpect(io, server, fd, select_1, "+OK\r\n");
        try resp_client.sendAndExpect(io, server, fd, "*3\r\n$3\r\nSET\r\n$6\r\nshared\r\n$5\r\nother\r\n", "+OK\r\n");
        try resp_client.sendAndExpect(io, server, fd, "*3\r\n$3\r\nSET\r\n$3\r\n\x00\r\n\r\n$8\r\nkept\x00\r\n\xff\r\n", "+OK\r\n");

        var timestamp_buffer: [24]u8 = undefined;
        const timestamp = try std.fmt.bufPrint(&timestamp_buffer, "{d}", .{expires_ms});
        var request_buffer: [256]u8 = undefined;
        const set_expiry = try std.fmt.bufPrint(&request_buffer, "*5\r\n$3\r\nSET\r\n$7\r\nexpires\r\n$5\r\nalive\r\n$4\r\nPXAT\r\n${d}\r\n{s}\r\n", .{ timestamp.len, timestamp });
        try resp_client.sendAndExpect(io, server, fd, set_expiry, "+OK\r\n");
    }
    try server.stop();
    const snapshot = try dir.openFile(io, "state.kgc", .{});
    defer snapshot.close(io);
    for (0..3) |cycle| {
        if (cycle == 2) {
            const remaining_ms = expires_ms - std.Io.Clock.real.now(io).toMilliseconds();
            if (remaining_ms <= 0) return error.ExpiryWindowTooShort;
            try io.sleep(.fromMilliseconds(remaining_ms + 1), .awake);
        }
        try server.start();
        {
            const client = try server.address.?.connect(io, .{ .mode = .stream });
            defer client.close(io);
            const fd = client.socket.handle;
            try resp_client.sendAndExpect(io, server, fd, "*2\r\n$3\r\nGET\r\n$6\r\nshared\r\n", "$3\r\nnew\r\n");
            try resp_client.sendAndExpect(io, server, fd, "*2\r\n$3\r\nGET\r\n$7\r\nremoved\r\n", "$-1\r\n");
            try resp_client.sendAndExpect(io, server, fd, binary_get, "$-1\r\n");
            try resp_client.sendAndExpect(io, server, fd, select_1, "+OK\r\n");
            try resp_client.sendAndExpect(io, server, fd, "*2\r\n$3\r\nGET\r\n$6\r\nshared\r\n", "$5\r\nother\r\n");
            try resp_client.sendAndExpect(io, server, fd, binary_get, "$8\r\nkept\x00\r\n\xff\r\n");
            try resp_client.sendAndExpect(io, server, fd, "*2\r\n$3\r\nGET\r\n$7\r\nexpires\r\n", if (cycle < 2) "$5\r\nalive\r\n" else "$-1\r\n");
        }
        try server.stop();
        if (cycle < 2) try expectSameSnapshot(io, dir, snapshot);
    }
}
