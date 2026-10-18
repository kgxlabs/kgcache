const std = @import("std");
const support = @import("server_process");
const resp_client = @import("../harness/resp_client.zig");

pub fn run(io: std.Io, allocator: std.mem.Allocator, executable_path: []const u8, controlled_path: []const u8, artifact_dir: ?[]const u8) !void {
    try checkSnapshot(io, allocator, executable_path, controlled_path, artifact_dir);
    try checkRewrite(io, allocator, executable_path, controlled_path, artifact_dir);
}

fn checkSnapshot(io: std.Io, allocator: std.mem.Allocator, executable_path: []const u8, controlled_path: []const u8, artifact_dir: ?[]const u8) !void {
    std.log.info("integration: signal stop during BGSAVE started", .{});
    for ([_]bool{ false, true }) |controlled| {
        const server = try support.ServerProcess.create(io, allocator, if (controlled) controlled_path else executable_path, .{
            .case_name = if (controlled) "BGSAVE overlap" else "BGSAVE stop",
            .extra_config = if (controlled)
                "appendonly no\nsave \"\"\ndbfilename state.kgc\n"
            else
                "appendonly no\nsave \"\"\ndbfilename state.kgc\nshutdown-save no\n",
            .control_child = if (controlled) .kgc else null,
            .artifact_dir = artifact_dir,
        });
        defer server.destroy();
        errdefer server.failed = true;
        {
            const client = try server.address.?.connect(io, .{ .mode = .stream });
            defer client.close(io);
            const fd = client.socket.handle;
            try resp_client.sendAndExpect(io, server, fd, "*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$3\r\nold\r\n", "+OK\r\n");
            try resp_client.sendAndExpect(io, server, fd, "*1\r\n$6\r\nBGSAVE\r\n", "+Background saving started\r\n");
            if (controlled) {
                _ = try server.waitForControl(.synced);
                try resp_client.sendAndExpect(io, server, fd, "*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$5\r\nfresh\r\n", "+OK\r\n");
            }
        }
        if (controlled) {
            try server.sendSignal(.TERM);
            _ = try server.waitForControl(.draining);
            try server.releaseChild();
            const reaped = try server.waitForControl(.reaped);
            if (!std.c.W.IFEXITED(reaped.status) or std.c.W.EXITSTATUS(reaped.status) != 0) return error.ChildFailed;
            try server.waitForExit(0);
        } else {
            try server.stop();
        }
        // Restart the normal binary to check the saved file without test controls.
        server.executable_path = executable_path;
        server.options.control_child = null;
        try server.start();
        {
            const client = try server.address.?.connect(io, .{ .mode = .stream });
            defer client.close(io);
            try resp_client.sendAndExpect(io, server, client.socket.handle, "*2\r\n$3\r\nGET\r\n$3\r\nkey\r\n", if (controlled) "$5\r\nfresh\r\n" else "$3\r\nold\r\n");
        }
        try server.stop();
    }
    std.log.info("integration: signal stop during BGSAVE passed", .{});
}

fn checkRewrite(io: std.Io, allocator: std.mem.Allocator, executable_path: []const u8, controlled_path: []const u8, artifact_dir: ?[]const u8) !void {
    std.log.info("integration: signal stop during AOF rewrite started", .{});
    for ([_]bool{ false, true }) |controlled| {
        const server = try support.ServerProcess.create(io, allocator, if (controlled) controlled_path else executable_path, .{
            .case_name = if (controlled) "AOF rewrite overlap" else "AOF rewrite stop",
            .extra_config = "appendonly yes\nappendfsync always\nauto-aof-rewrite-percentage 0\nsave \"\"\ndbfilename state.kgc\n",
            .control_child = if (controlled) .aof else null,
            .artifact_dir = artifact_dir,
        });
        defer server.destroy();
        errdefer server.failed = true;
        var dir = try std.Io.Dir.cwd().openDir(io, server.data_dir, .{});
        defer dir.close(io);
        {
            const client = try server.address.?.connect(io, .{ .mode = .stream });
            defer client.close(io);
            const fd = client.socket.handle;
            try resp_client.sendAndExpect(io, server, fd, "*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$3\r\nold\r\n", "+OK\r\n");
            try resp_client.sendAndExpect(io, server, fd, "*1\r\n$12\r\nBGREWRITEAOF\r\n", "+Background append only file rewriting started\r\n");
            if (controlled) {
                _ = try server.waitForControl(.synced);
                try resp_client.sendAndExpect(io, server, fd, "*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$5\r\nfresh\r\n", "+OK\r\n");
                try resp_client.sendAndExpect(io, server, fd, "*3\r\n$3\r\nSET\r\n$5\r\nlater\r\n$5\r\nadded\r\n", "+OK\r\n");
            }
        }
        if (controlled) {
            try server.sendSignal(.TERM);
            _ = try server.waitForControl(.draining);
            try server.releaseChild();
            const reaped = try server.waitForControl(.reaped);
            if (!std.c.W.IFEXITED(reaped.status) or std.c.W.EXITSTATUS(reaped.status) != 0) return error.ChildFailed;
            try server.waitForExit(0);
        } else {
            try server.stop();
        }
        const manifest = try dir.readFileAlloc(io, "aof/appendonly.aof.manifest", allocator, .limited(4096));
        defer allocator.free(manifest);
        var has_base = false;
        var has_incremental = false;
        var lines = std.mem.tokenizeScalar(u8, manifest, '\n');
        while (lines.next()) |line| {
            var fields = std.mem.tokenizeScalar(u8, line, ' ');
            if (!std.mem.eql(u8, fields.next() orelse return error.InvalidManifest, "file")) return error.InvalidManifest;
            const name = fields.next() orelse return error.InvalidManifest;
            const path = try std.fs.path.join(allocator, &.{ "aof", name });
            defer allocator.free(path);
            const stat = try dir.statFile(io, path, .{});
            if (std.mem.endsWith(u8, line, " type b")) {
                if (stat.size == 0) return error.EmptyAofBase;
                has_base = true;
            }
            if (std.mem.endsWith(u8, line, " type i")) has_incremental = true;
        }
        if (!has_base or !has_incremental) return error.RewriteNotPublished;
        if (dir.access(io, "state.kgc", .{})) |_| {
            return error.UnexpectedSnapshot;
        } else |err| {
            if (err != error.FileNotFound) return err;
        }
        server.executable_path = executable_path;
        server.options.control_child = null;
        try server.start();
        {
            const client = try server.address.?.connect(io, .{ .mode = .stream });
            defer client.close(io);
            const fd = client.socket.handle;
            try resp_client.sendAndExpect(io, server, fd, "*2\r\n$3\r\nGET\r\n$3\r\nkey\r\n", if (controlled) "$5\r\nfresh\r\n" else "$3\r\nold\r\n");
            if (controlled) try resp_client.sendAndExpect(io, server, fd, "*2\r\n$3\r\nGET\r\n$5\r\nlater\r\n", "$5\r\nadded\r\n");
        }
        try server.stop();
    }
    std.log.info("integration: signal stop during AOF rewrite passed", .{});
}
