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
    for (cases) |case| {
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
            try resp_client.sendAndExpect(io, server, fd, "*3\r\n$3\r\nSET\r\n$4\r\nkept\r\n$5\r\nfresh\r\n", "+OK\r\n");
            try resp_client.sendAndExpect(io, server, fd, "*2\r\n$3\r\nDEL\r\n$7\r\nremoved\r\n", ":1\r\n");
        }
        try server.stopWithSignal(case.signal);
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
            try resp_client.sendAndExpect(io, server, fd, "*2\r\n$3\r\nGET\r\n$4\r\nkept\r\n", "$5\r\nfresh\r\n");
            try resp_client.sendAndExpect(io, server, fd, "*2\r\n$3\r\nGET\r\n$7\r\nremoved\r\n", "$-1\r\n");
        }
        try server.stop();
    }
    std.log.info("integration: AOF clean signal stops passed", .{});
}
