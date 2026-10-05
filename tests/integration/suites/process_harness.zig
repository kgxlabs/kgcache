const std = @import("std");
const harness = @import("server_process");
const ServerProcess = harness.ServerProcess;
const resp_client = @import("../harness/resp_client.zig");

pub fn run(io: std.Io, allocator: std.mem.Allocator, executable_path: []const u8, fake_executable_path: []const u8, artifact_dir: ?[]const u8) !void {
    std.log.info("integration: process harness checks started", .{});

    var random_bytes: [8]u8 = undefined;
    std.Io.random(io, &random_bytes);
    const artifact_suffix = std.fmt.bytesToHex(random_bytes, .lower);
    const artifact_root = try std.fmt.allocPrint(allocator, "/tmp/kgcache-artifact-check-{s}", .{artifact_suffix});
    defer allocator.free(artifact_root);
    defer std.Io.Dir.cwd().deleteTree(io, artifact_root) catch {};

    try checkStartupFailures(io, allocator, executable_path, fake_executable_path, artifact_root);
    try checkStartupArguments(io, allocator, executable_path, artifact_dir);
    try checkReadinessArguments(io, allocator, executable_path, artifact_dir);
    try checkPortsAndRestarts(io, allocator, executable_path, artifact_dir);
    try checkLogCaptureLimit(io, allocator, fake_executable_path);
    try checkHungProcess(io, allocator, fake_executable_path, artifact_root);

    std.log.info("integration: process harness checks passed", .{});
}

fn checkStartupFailures(io: std.Io, allocator: std.mem.Allocator, executable_path: []const u8, fake_executable_path: []const u8, artifact_root: []const u8) !void {
    var missing_bytes: [12]u8 = undefined;
    std.Io.random(io, &missing_bytes);
    const missing_suffix = std.fmt.bytesToHex(missing_bytes, .lower);
    const missing_path = try std.fmt.allocPrint(allocator, "/tmp/kgcache-missing-{s}", .{missing_suffix});
    defer allocator.free(missing_path);

    try expectStartError(io, allocator, missing_path, .{
        .report_failures = false,
    }, error.FileNotFound);
    try expectStartError(io, allocator, executable_path, .{
        .extra_config = "unknown-option yes\n",
        .report_failures = false,
    }, error.StartupExited);
    try expectStartError(io, allocator, fake_executable_path, .{
        .extra_config = "fake-mode empty\n",
        .report_failures = false,
    }, error.EmptyReady);
    try expectStartError(io, allocator, fake_executable_path, .{
        .extra_config = "fake-mode malformed\n",
        .report_failures = false,
    }, error.MalformedReady);
    try expectStartError(io, allocator, fake_executable_path, .{
        .extra_config = "fake-mode incomplete\n",
        .report_failures = false,
    }, error.IncompleteReady);
    try expectStartError(io, allocator, fake_executable_path, .{
        .extra_config = "fake-mode startup-timeout\n",
        .startup_timeout_ms = 200,
        .report_failures = false,
    }, error.StartupTimeout);
    try expectStartError(io, allocator, fake_executable_path, .{
        .extra_config = "fake-mode assert\n",
        .artifact_dir = artifact_root,
        .report_failures = false,
    }, error.StartupExited);
    if (!try bundleHasText(io, allocator, artifact_root, "fake assertion")) return error.MissingAssertionArtifact;
}

fn checkStartupArguments(io: std.Io, allocator: std.mem.Allocator, executable_path: []const u8, artifact_dir: ?[]const u8) !void {
    const overrides = &[_][]const u8{ "--bind", "127.0.0.1", "--port", "0" };
    const cases = [_]struct { config_subpath: ?[]const u8, config_arg_index: usize }{
        .{ .config_subpath = "kgcache.conf", .config_arg_index = 0 },
        .{ .config_subpath = "kgcache.conf", .config_arg_index = 2 },
        .{ .config_subpath = "kgcache.conf", .config_arg_index = overrides.len },
        .{ .config_subpath = null, .config_arg_index = 0 },
    };
    for (cases) |case| {
        const server = try ServerProcess.create(io, allocator, executable_path, .{
            .config_subpath = case.config_subpath,
            .config_arg_index = case.config_arg_index,
            .extra_config = "bind 0.0.0.0\n",
            .extra_args = overrides,
            .artifact_dir = artifact_dir,
        });
        defer server.destroy();
        errdefer server.failed = true;
        const selected_port = server.address.?.getPort();
        try expectPing(io, server);
        for (0..2) |_| {
            try server.restart();
            if (server.address.?.getPort() != selected_port) return error.RestartChangedPort;
            try expectPing(io, server);
        }
        try server.stop();
        if (case.config_subpath == null) {
            const working_dir = try std.Io.Dir.cwd().openDir(io, server.data_dir, .{});
            defer working_dir.close(io);
            try std.testing.expectError(error.FileNotFound, working_dir.access(io, "kgcache.conf", .{}));
        }
    }
}

fn checkReadinessArguments(io: std.Io, allocator: std.mem.Allocator, executable_path: []const u8, artifact_dir: ?[]const u8) !void {
    const cases = [_]struct { args: []const []const u8, source: anyerror }{
        .{ .args = &.{"--ready-fd"}, .source = error.MissingReadyFd },
        .{ .args = &.{ "--ready-fd", "abc" }, .source = error.InvalidReadyFd },
        .{ .args = &.{ "--ready-fd", "2" }, .source = error.InvalidReadyFd },
        .{ .args = &.{ "--ready-fd", "3", "--ready-fd", "4" }, .source = error.DuplicateReadyFd },
    };
    for ([_]bool{ true, false }) |with_file| {
        for (cases) |case| {
            const server = try ServerProcess.createStopped(io, allocator, executable_path, .{
                .config_subpath = if (with_file) "kgcache.conf" else null,
                .extra_args = case.args,
                .auto_ready_fd = false,
                .artifact_dir = artifact_dir,
                .report_failures = false,
            });
            defer server.destroy();
            errdefer server.failed = true;
            try std.testing.expectError(error.StartupExited, server.start());
            if (server.ready_bytes_read != 0) return error.UnexpectedReadyOutput;
            const status = server.last_exit_status orelse return error.MissingExitStatus;
            if (!std.c.W.IFEXITED(status) or std.c.W.EXITSTATUS(status) != 1) return error.WrongExitStatus;
            if (server.pid != null) return error.UnreapedChild;
            const expected = try std.fmt.allocPrint(allocator, "[error] app: invalid command line: {s}\n", .{@errorName(case.source)});
            defer allocator.free(expected);
            if (std.mem.indexOf(u8, server.stderr.bytes(), expected) == null) return error.WrongReadinessError;
            if (std.mem.count(u8, server.stderr.bytes(), "[error] ") != 1) return error.UnexpectedErrorEventCount;
            server.failed = false;
        }
    }
}

fn expectPing(io: std.Io, server: *ServerProcess) !void {
    const client = try server.address.?.connect(io, .{ .mode = .stream });
    defer client.close(io);
    try resp_client.sendAndExpect(io, server, client.socket.handle, "*1\r\n$4\r\nPING\r\n", "+PONG\r\n");
}

fn checkPortsAndRestarts(io: std.Io, allocator: std.mem.Allocator, executable_path: []const u8, artifact_dir: ?[]const u8) !void {
    const first = try ServerProcess.create(io, allocator, executable_path, .{ .artifact_dir = artifact_dir });
    defer first.destroy();
    errdefer first.failed = true;
    const selected_port = first.address.?.getPort();
    if (selected_port == 0) return error.ZeroSelectedPort;
    if (std.mem.indexOf(u8, first.config.?, "port 0\n") == null) return error.MissingInitialPort;

    const second = try ServerProcess.create(io, allocator, executable_path, .{
        .artifact_dir = artifact_dir,
        .extra_config = "reuse-address no\n",
        .report_failures = false,
    });
    defer second.destroy();
    errdefer second.failed = true;

    if (second.address.?.getPort() == selected_port) return error.SharedPort;
    try second.stop();
    second.address = first.address;
    if (second.start()) |_| return error.ExpectedBindFailure else |err| {
        if (err != error.StartupExited) return err;
    }
    if (second.pid != null) return error.UnreapedChild;
    second.failed = false;

    const bound_port = try std.fmt.allocPrint(allocator, "port {d}\n", .{selected_port});
    defer allocator.free(bound_port);
    if (std.mem.indexOf(u8, second.config.?, bound_port) == null) return error.BindConfigWrongPort;

    for (0..3) |_| {
        try first.stop();
        try first.start();
        if (first.address.?.getPort() != selected_port) return error.RestartChangedPort;
        const expected = try std.fmt.allocPrint(allocator, "port {d}\n", .{selected_port});
        defer allocator.free(expected);
        if (std.mem.indexOf(u8, first.config.?, expected) == null) return error.RestartConfigWrongPort;
    }
    try first.restart();
    if (first.address.?.getPort() != selected_port) return error.RestartChangedPort;
    try first.stop();
}

fn checkLogCaptureLimit(io: std.Io, allocator: std.mem.Allocator, fake_executable_path: []const u8) !void {
    const noisy = try ServerProcess.create(io, allocator, fake_executable_path, .{
        .extra_config = "fake-mode flood\n",
        .report_failures = false,
    });
    defer noisy.destroy();

    try std.testing.expectError(error.UncleanShutdown, noisy.stop());

    if (!noisy.stdout.truncated or !noisy.stderr.truncated) return error.LogLimitNotReached;
    if (noisy.stdout.bytes().len != 16 * 1024 or noisy.stderr.bytes().len != 16 * 1024) return error.UnboundedLog;
}

fn checkHungProcess(io: std.Io, allocator: std.mem.Allocator, fake_executable_path: []const u8, artifact_root: []const u8) !void {
    const hung = try ServerProcess.create(io, allocator, fake_executable_path, .{
        .extra_config = "fake-mode stop-timeout\n",
        .stop_timeout_ms = 200,
        .read_timeout_ms = 100,
        .artifact_dir = artifact_root,
        .report_failures = false,
    });
    var hung_live = true;
    defer if (hung_live) hung.destroy();
    const hung_pid = hung.pid.?;

    var pipe_fds: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&pipe_fds) != 0) return error.PipeFailed;
    defer _ = std.c.close(pipe_fds[0]);
    defer _ = std.c.close(pipe_fds[1]);

    var one: [1]u8 = undefined;

    if (hung.readExact(pipe_fds[0], &one)) |_| return error.ExpectedProtocolReadTimeout else |err| {
        if (err != error.ProtocolReadTimeout) return err;
    }

    if (hung.stop()) |_| return error.ExpectedShutdownTimeout else |err| {
        if (err != error.ShutdownTimeout) return err;
    }
    if (hung.pid != null) return error.UnreapedChild;
    if (std.posix.kill(hung_pid, @enumFromInt(0))) |_| return error.ChildStillAlive else |err| {
        if (err != error.ProcessNotFound) return err;
    }
    if (std.mem.indexOf(u8, hung.stderr.bytes(), "fake shutdown hang") == null) return error.MissingCapturedLog;
    const saved_log_path = try std.fmt.allocPrint(allocator, "{s}/{s}/stderr.log", .{
        artifact_root, std.fs.path.basename(hung.data_dir),
    });
    defer allocator.free(saved_log_path);
    hung.destroy();
    hung_live = false;
    const saved_log = try std.Io.Dir.cwd().readFileAlloc(io, saved_log_path, allocator, .limited(16 * 1024 + 1));
    defer allocator.free(saved_log);
    if (std.mem.indexOf(u8, saved_log, "fake shutdown hang") == null) return error.MissingSavedLog;
}

fn expectStartError(io: std.Io, allocator: std.mem.Allocator, executable_path: []const u8, options: harness.Options, expected: anyerror) !void {
    if (ServerProcess.create(io, allocator, executable_path, options)) |server| {
        server.destroy();
        return error.ExpectedStartupFailure;
    } else |err| {
        if (err != expected) return err;
    }
}

fn bundleHasText(io: std.Io, allocator: std.mem.Allocator, root: []const u8, needle: []const u8) !bool {
    const dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var entries = dir.iterate();
    while (try entries.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const log_path = try std.fmt.allocPrint(allocator, "{s}/{s}/stderr.log", .{ root, entry.name });
        defer allocator.free(log_path);
        const log = try std.Io.Dir.cwd().readFileAlloc(io, log_path, allocator, .limited(16 * 1024 + 1));
        defer allocator.free(log);
        if (std.mem.indexOf(u8, log, needle) != null) return true;
    }
    return false;
}
