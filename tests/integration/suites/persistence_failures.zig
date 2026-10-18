const std = @import("std");
const support = @import("server_process");
const resp_client = @import("../harness/resp_client.zig");

const Failure = enum { snapshot_write, rewrite_write, publication, timeout };

pub fn run(io: std.Io, allocator: std.mem.Allocator, executable_path: []const u8, controlled_path: []const u8, artifact_dir: ?[]const u8) !void {
    std.log.info("integration: failed persistence process stops started", .{});
    for ([_]Failure{ .snapshot_write, .rewrite_write, .publication, .timeout }) |failure| {
        const rewrite = failure == .rewrite_write;
        const write_failure = failure == .snapshot_write or rewrite;
        const server = try support.ServerProcess.createStopped(io, allocator, controlled_path, .{
            .case_name = @tagName(failure),
            .extra_config = if (rewrite)
                "dir data\nappendonly yes\nappendfsync always\nauto-aof-rewrite-percentage 0\nsave \"\"\npersistence-shutdown-grace-ms 1000\n"
            else
                "dir data\nappendonly no\nsave \"\"\ndbfilename state.kgc\npersistence-shutdown-grace-ms 1000\n",
            .control_child = if (rewrite) .aof else .kgc,
            .control_stage = if (write_failure) .before_write else .synced,
            .stop_timeout_ms = 3_500,
            .read_timeout_ms = 3_500,
            .artifact_dir = artifact_dir,
        });
        defer server.destroy();
        errdefer server.failed = true;
        var root = try std.Io.Dir.cwd().openDir(io, server.data_dir, .{});
        defer root.close(io);
        try root.createDir(io, "data", .default_dir);
        var data = try root.openDir(io, "data", .{});
        defer data.close(io);
        var directory_moved = false;
        defer {
            if (directory_moved) root.rename("saved-data", root, "data", io) catch {};
        }
        try server.start();
        var old_snapshot: ?std.Io.File = null;
        defer if (old_snapshot) |file| file.close(io);
        {
            const client = try server.address.?.connect(io, .{ .mode = .stream });
            defer client.close(io);
            const fd = client.socket.handle;
            try resp_client.sendAndExpect(io, server, fd, "*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$3\r\nold\r\n", "+OK\r\n");
            if (rewrite) {
                try resp_client.sendAndExpect(io, server, fd, "*1\r\n$12\r\nBGREWRITEAOF\r\n", "+Background append only file rewriting started\r\n");
                _ = try server.waitForControl(.before_write);
            } else {
                try resp_client.sendAndExpect(io, server, fd, "*1\r\n$4\r\nSAVE\r\n", "+OK\r\n");
                old_snapshot = try data.openFile(io, "state.kgc", .{});
            }
            try resp_client.sendAndExpect(io, server, fd, "*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$5\r\nfresh\r\n", "+OK\r\n");
            if (rewrite) try resp_client.sendAndExpect(io, server, fd, "*3\r\n$3\r\nSET\r\n$5\r\nlater\r\n$5\r\nadded\r\n", "+OK\r\n");
        }
        const stop_started = std.Io.Clock.awake.now(io).toMilliseconds();
        try server.sendSignal(.TERM);
        if (rewrite) {
            _ = try server.waitForControl(.draining);
        } else {
            _ = try server.waitForControl(server.options.control_stage);
        }
        if (failure == .publication) {
            // The child has synced output. Only the parent's rename will fail.
            try root.rename("data", root, "saved-data", io);
            directory_moved = true;
        }
        if (write_failure) {
            try server.failChildWrite();
        } else if (failure != .timeout) {
            try server.releaseChild();
        }
        const reaped = try server.waitForControl(.reaped);
        if (failure == .timeout) {
            if (!std.c.W.IFSIGNALED(reaped.status) or std.c.W.TERMSIG(reaped.status) != .KILL) return error.ChildNotKilled;
        } else {
            const expected: u8 = if (write_failure) 1 else 0;
            if (!std.c.W.IFEXITED(reaped.status) or std.c.W.EXITSTATUS(reaped.status) != expected) return error.WrongChildExit;
        }
        try server.waitForExit(1);
        if (failure == .timeout) {
            // Work: 1000 ms. Reap: 1000 ms. Allow 1500 ms for scheduling.
            if (std.Io.Clock.awake.now(io).toMilliseconds() - stop_started > 3_500) return error.UnboundedPersistenceStop;
        }
        const source = switch (failure) {
            .snapshot_write => "BackgroundSaveFailed",
            .rewrite_write => "AofRewriteFailed",
            .publication => "FileNotFound",
            .timeout => "PersistenceShutdownTimeout",
        };
        const report = if (rewrite) "server: BGREWRITEAOF child failed" else "server: BGSAVE child failed";
        if (std.mem.indexOf(u8, server.stdout.bytes(), source) == null and std.mem.indexOf(u8, server.stderr.bytes(), source) == null) return error.MissingFailureSource;
        if (std.mem.count(u8, server.stdout.bytes(), report) + std.mem.count(u8, server.stderr.bytes(), report) != 1) return error.WrongFailureReportCount;
        if (directory_moved) {
            try root.rename("saved-data", root, "data", io);
            directory_moved = false;
        }
        if (old_snapshot) |file| {
            const before = try file.stat(io);
            const after = try data.statFile(io, "state.kgc", .{});
            if (before.inode != after.inode) return error.FailedSaveReplacedSnapshot;
        }
        server.executable_path = executable_path;
        server.options.control_child = null;
        try server.start();
        {
            const client = try server.address.?.connect(io, .{ .mode = .stream });
            defer client.close(io);
            const fd = client.socket.handle;
            try resp_client.sendAndExpect(io, server, fd, "*2\r\n$3\r\nGET\r\n$3\r\nkey\r\n", if (rewrite) "$5\r\nfresh\r\n" else "$3\r\nold\r\n");
            if (rewrite) try resp_client.sendAndExpect(io, server, fd, "*2\r\n$3\r\nGET\r\n$5\r\nlater\r\n", "$5\r\nadded\r\n");
        }
        try server.stop();
    }
    std.log.info("integration: failed persistence process stops passed", .{});
}
