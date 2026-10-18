const std = @import("std");
const support = @import("server_process");
const resp_client = @import("../harness/resp_client.zig");

pub fn run(io: std.Io, allocator: std.mem.Allocator, executable_path: []const u8, artifact_dir: ?[]const u8) !void {
    std.log.info("integration: AOF clean signal stops started", .{});
    const cases = [_]struct { policy: []const u8, signal: std.posix.SIG }{
        .{ .policy = "everysec", .signal = .TERM },
        .{ .policy = "no", .signal = .TERM },
        .{ .policy = "everysec", .signal = .INT },
    };
    for (cases, 0..) |case, index| {
        const repeated_restart = index == 0;
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var saved_files = std.StringHashMap([]const u8).init(arena.allocator());
        const config = try std.fmt.allocPrint(allocator, "appendonly yes\nappendfsync {s}\nauto-aof-rewrite-percentage 0\nsave \"\"\ndbfilename state.kgc\n", .{case.policy});
        defer allocator.free(config);
        const server = try support.ServerProcess.create(io, allocator, executable_path, .{
            .extra_config = config,
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
            try resp_client.sendAndExpect(io, server, fd, "*3\r\n$3\r\nSET\r\n$4\r\nkept\r\n$3\r\nold\r\n", "+OK\r\n");
            try resp_client.sendAndExpect(io, server, fd, "*3\r\n$3\r\nSET\r\n$7\r\nremoved\r\n$3\r\nold\r\n", "+OK\r\n");
            if (!repeated_restart) try updateAndDelete(io, server, fd);
        }
        try server.stopWithSignal(case.signal);
        if (dir.access(io, "state.kgc", .{})) |_| {
            return error.UnexpectedSnapshot;
        } else |err| {
            if (err != error.FileNotFound) return err;
        }
        if (repeated_restart) {
            try server.start();
            {
                const client = try server.address.?.connect(io, .{ .mode = .stream });
                defer client.close(io);
                const fd = client.socket.handle;
                try resp_client.sendAndExpect(io, server, fd, "*2\r\n$3\r\nGET\r\n$4\r\nkept\r\n", "$3\r\nold\r\n");
                try resp_client.sendAndExpect(io, server, fd, "*2\r\n$3\r\nGET\r\n$7\r\nremoved\r\n", "$3\r\nold\r\n");
                try updateAndDelete(io, server, fd);
            }
            try server.stop();

            const manifest_path = "aof/appendonly.aof.manifest";
            const manifest = try dir.readFileAlloc(io, manifest_path, arena.allocator(), .limited(4096));
            try saved_files.put(manifest_path, manifest);
            var lines = std.mem.tokenizeScalar(u8, manifest, '\n');
            while (lines.next()) |line| {
                var fields = std.mem.tokenizeScalar(u8, line, ' ');
                if (!std.mem.eql(u8, fields.next() orelse return error.InvalidManifest, "file")) return error.InvalidManifest;
                const name = fields.next() orelse return error.InvalidManifest;
                const path = try std.fs.path.join(arena.allocator(), &.{ "aof", name });
                const bytes = try dir.readFileAlloc(io, path, arena.allocator(), .limited(4096));
                try saved_files.put(path, bytes);
            }
            if (saved_files.count() < 2) return error.EmptyManifest;
        }
        try server.start();
        {
            const client = try server.address.?.connect(io, .{ .mode = .stream });
            defer client.close(io);
            const fd = client.socket.handle;
            try resp_client.sendAndExpect(io, server, fd, "*2\r\n$3\r\nGET\r\n$4\r\nkept\r\n", "$5\r\nfresh\r\n");
            try resp_client.sendAndExpect(io, server, fd, "*2\r\n$3\r\nGET\r\n$7\r\nremoved\r\n", "$-1\r\n");
        }
        try server.stop();
        var files = saved_files.iterator();
        while (files.next()) |file| {
            const after = try dir.readFileAlloc(io, file.key_ptr.*, allocator, .limited(4096));
            defer allocator.free(after);
            if (!std.mem.eql(u8, file.value_ptr.*, after)) return error.ReplayChangedAof;
        }
    }
    std.log.info("integration: AOF clean signal stops passed", .{});
}

fn updateAndDelete(io: std.Io, server: *support.ServerProcess, fd: std.posix.fd_t) !void {
    try resp_client.sendAndExpect(io, server, fd, "*3\r\n$3\r\nSET\r\n$4\r\nkept\r\n$5\r\nfresh\r\n", "+OK\r\n");
    try resp_client.sendAndExpect(io, server, fd, "*2\r\n$3\r\nDEL\r\n$7\r\nremoved\r\n", ":1\r\n");
}
