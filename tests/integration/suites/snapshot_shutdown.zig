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
    }{
        .{ .config = "save 3600 1\n" },
        .{ .config = "save \"\"\n" },
        .{ .config = "save \"\"\n", .previous_snapshot = true },
        .{ .config = "save \"\"\nshutdown-save no\n", .saved = false },
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
        {
            const client = try server.address.?.connect(io, .{ .mode = .stream });
            defer client.close(io);
            const fd = client.socket.handle;
            if (case.previous_snapshot) {
                try resp_client.sendAndExpect(io, server, fd, "*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$3\r\nold\r\n", "+OK\r\n");
                try resp_client.sendAndExpect(io, server, fd, "*1\r\n$4\r\nSAVE\r\n", "+OK\r\n");
            }
            try resp_client.sendAndExpect(io, server, fd, "*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$5\r\nfresh\r\n", "+OK\r\n");
        }
        try server.stop();
        try server.start();
        {
            const client = try server.address.?.connect(io, .{ .mode = .stream });
            defer client.close(io);
            try resp_client.sendAndExpect(io, server, client.socket.handle, "*2\r\n$3\r\nGET\r\n$3\r\nkey\r\n", if (case.saved) "$5\r\nfresh\r\n" else "$-1\r\n");
        }
        try server.stop();
    }
    std.log.info("integration: final shutdown snapshot passed", .{});
}
