const std = @import("std");
const support = @import("server_process");
const resp_client = @import("../harness/resp_client.zig");

pub fn run(io: std.Io, allocator: std.mem.Allocator, executable_path: []const u8, controlled_path: []const u8, artifact_dir: ?[]const u8) !void {
    std.log.info("integration: signal stop during BGSAVE started", .{});
    for ([_]bool{ false, true }) |controlled| {
        const server = try support.ServerProcess.create(io, allocator, if (controlled) controlled_path else executable_path, .{
            .extra_config = if (controlled)
                "appendonly no\nsave \"\"\ndbfilename state.kgc\n"
            else
                "appendonly no\nsave \"\"\ndbfilename state.kgc\nshutdown-save no\n",
            .control_child = controlled,
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
            try std.posix.kill(server.pid.?, .TERM);
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
        server.options.control_child = false;
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
