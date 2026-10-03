const std = @import("std");
const support = @import("server_process");

pub fn run(io: std.Io, allocator: std.mem.Allocator, executable_path: []const u8, artifact_dir: ?[]const u8) !void {
    std.log.info("integration: invalid config startup started", .{});
    for ([_][]const u8{
        "unknown-option yes\n",
        "num-databases 4\n",
        "append-dirname history\n",
        "append-filename journal.aof\n",
        "snapshot-path state.kgc\n",
    }) |extra_config| {
        try checkRejectedConfig(io, allocator, executable_path, artifact_dir, extra_config);
    }
    std.log.info("integration: invalid config startup passed", .{});
}

fn checkRejectedConfig(io: std.Io, allocator: std.mem.Allocator, executable_path: []const u8, artifact_dir: ?[]const u8, extra_config: []const u8) !void {
    const server = try support.ServerProcess.createStopped(io, allocator, executable_path, .{
        .extra_config = extra_config,
        .artifact_dir = artifact_dir,
        .report_failures = false,
    });
    defer server.destroy();
    errdefer {
        server.failed = true;
        std.log.err("integration: invalid config {s} failed; stdout: {s}; stderr: {s}", .{
            extra_config, server.stdout.bytes(), server.stderr.bytes(),
        });
    }

    try expectStartupExit(server);

    if (server.ready_bytes_read != 0) return error.UnexpectedReadyOutput;
    const status = server.last_exit_status orelse return error.MissingExitStatus;
    if (!std.c.W.IFEXITED(status) or std.c.W.EXITSTATUS(status) != 1) return error.WrongExitStatus;
    if (server.pid != null) return error.UnreapedChild;

    server.failed = false;
}

fn expectStartupExit(server: *support.ServerProcess) !void {
    server.start() catch |err| {
        if (err == error.StartupExited) return;
        return err;
    };

    return error.ExpectedStartupFailure;
}
