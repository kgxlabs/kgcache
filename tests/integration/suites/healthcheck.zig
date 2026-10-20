const std = @import("std");
const support = @import("server_process");

pub fn run(io: std.Io, allocator: std.mem.Allocator, executable: []const u8, controlled_executable: []const u8, artifact_dir: ?[]const u8) !void {
    std.log.info("integration: health command started", .{});
    const server = try support.ServerProcess.create(io, allocator, executable, .{
        .artifact_dir = artifact_dir,
    });
    defer server.destroy();
    errdefer server.failed = true;

    const port = try std.fmt.allocPrint(allocator, "{d}", .{server.address.?.getPort()});
    defer allocator.free(port);
    const config = try std.fmt.allocPrint(allocator, "bind 0.0.0.0\nport {s}\nappendonly yes\ndir /dev/null/inaccessible\n", .{port});
    defer allocator.free(config);
    var dir = try std.Io.Dir.cwd().openDir(io, server.data_dir, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = "probe.conf", .data = config });
    try dir.writeFile(io, .{ .sub_path = "healthcheck", .data = config });
    try dir.writeFile(io, .{ .sub_path = "wrong.conf", .data = "port 0\n" });
    try dir.writeFile(io, .{ .sub_path = "bad.conf", .data = "port invalid\n" });

    const success_cases = [_][]const []const u8{
        &.{"probe.conf"},
        &.{"./healthcheck"},
        &.{ "--port", port },
        &.{ "wrong.conf", "--port", port },
        &.{ "--port", port, "wrong.conf" },
        &.{ "--port", "0", "--port", port, "wrong.conf", "--bind", "127.0.0.1" },
        &.{ "probe.conf", "--dir", "missing/child", "--databases", "4", "--save", "60", "1" },
    };
    for (success_cases) |args| try command(io, allocator, executable, server.data_dir, args, null);

    const failures = [_]struct { args: []const []const u8, diagnostic: []const u8 }{
        .{ .args = &.{"wrong.conf"}, .diagnostic = "concrete port" },
        .{ .args = &.{"bad.conf"}, .diagnostic = "invalid configuration" },
        .{ .args = &.{"absent.conf"}, .diagnostic = "invalid configuration" },
        .{ .args = &.{ "--bind", "localhost" }, .diagnostic = "numeric IPv4" },
        .{ .args = &.{ "--bind", "::1" }, .diagnostic = "numeric IPv4" },
        .{ .args = &.{ "--bind", "999.0.0.1" }, .diagnostic = "numeric IPv4" },
        .{ .args = &.{ "--port", "invalid", "--port", port }, .diagnostic = "invalid command line" },
        .{ .args = &.{ "probe.conf", "--unknown" }, .diagnostic = "invalid command line" },
        .{ .args = &.{ "probe.conf", "wrong.conf" }, .diagnostic = "invalid command line" },
        .{ .args = &.{"--port"}, .diagnostic = "invalid command line" },
        .{ .args = &.{ "--ready-fd", "3" }, .diagnostic = "ReadyFdInHealthMode" },
    };
    for (failures) |case| try command(io, allocator, executable, server.data_dir, case.args, case.diagnostic);

    // Invalid persistence controls must not run in health mode, even in a test build.
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try environment.put("KGCACHE_TEST_CONTROL", "invalid-health-control");
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ controlled_executable, "healthcheck", "probe.conf" },
        .cwd = .{ .path = server.data_dir },
        .environ_map = &environment,
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
        .timeout = deadline(io),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try checkResult(result, null);

    // A real inherited descriptor must receive no readiness bytes.
    const ready = try support.ServerProcess.createStopped(io, allocator, executable, .{
        .extra_args = &.{"healthcheck"},
        .config_arg_index = 1,
        .artifact_dir = artifact_dir,
        .report_failures = false,
    });
    defer ready.destroy();
    errdefer ready.failed = true;
    if (ready.start()) |_| return error.ExpectedHealthReadyFdRejection else |err| {
        if (err != error.StartupExited) return err;
    }
    if (ready.ready_bytes_read != 0) return error.UnexpectedHealthReadiness;
    if (std.mem.indexOf(u8, ready.stderr.bytes(), "ReadyFdInHealthMode") == null) return error.MissingReadyFdDiagnostic;
    ready.failed = false;

    try server.stop();
    try command(io, allocator, executable, server.data_dir, &.{"probe.conf"}, "connection failed");
    for ([_]PeerMode{ .fragmented, .silent, .slow, .eof, .short, .malformed, .err, .bulk, .integer }) |mode| {
        try controlledPeer(io, allocator, executable, mode);
    }
    std.log.info("integration: health command passed", .{});
}

fn deadline(io: std.Io) std.Io.Timeout {
    return .{ .deadline = std.Io.Clock.Timestamp.now(io, .awake).addDuration(.{
        .raw = .fromMilliseconds(4000),
        .clock = .awake,
    }) };
}

fn command(io: std.Io, allocator: std.mem.Allocator, executable: []const u8, cwd: []const u8, args: []const []const u8, diagnostic: ?[]const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ executable, "healthcheck" });
    try argv.appendSlice(allocator, args);
    const result = try std.process.run(allocator, io, .{
        .argv = argv.items,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
        .timeout = deadline(io),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    errdefer std.log.err("health command: args {any}, status {any}, stderr {s}", .{ args, result.term, result.stderr });
    try checkResult(result, diagnostic);
}

fn checkResult(result: std.process.RunResult, diagnostic: ?[]const u8) !void {
    if (result.term != .exited or result.term.exited != @as(u8, if (diagnostic == null) 0 else 1)) return error.WrongHealthExit;
    if (result.stdout.len != 0) return error.UnexpectedHealthStdout;
    if (diagnostic) |text| {
        if (result.stderr.len > 512 or !std.mem.endsWith(u8, result.stderr, "\n") or
            std.mem.count(u8, result.stderr, "\n") != 1 or
            std.mem.indexOf(u8, result.stderr, text) == null) return error.WrongHealthDiagnostic;
    } else if (result.stderr.len != 0) return error.UnexpectedHealthStderr;
}

const PeerMode = enum { fragmented, silent, slow, eof, short, malformed, err, bulk, integer };

fn controlledPeer(io: std.Io, allocator: std.mem.Allocator, executable: []const u8, mode: PeerMode) !void {
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var listener = try address.listen(io, .{});
    defer listener.deinit(io);
    var peer = try io.concurrent(serve, .{ io, &listener, mode });
    defer _ = peer.cancel(io) catch {};
    const port = try std.fmt.allocPrint(allocator, "{d}", .{listener.socket.address.getPort()});
    defer allocator.free(port);
    const diagnostic: ?[]const u8 = switch (mode) {
        .fragmented => null,
        .silent, .slow => "deadline expired",
        else => "unexpected reply",
    };
    try command(io, allocator, executable, ".", &.{ "--port", port }, diagnostic);
    try peer.await(io);
}

fn serve(io: std.Io, listener: *std.Io.net.Server, mode: PeerMode) !void {
    const stream = try listener.accept(io);
    defer stream.close(io);
    var read_buffer: [64]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var bytes: [14]u8 = undefined;
    try reader.interface.readSliceAll(&bytes);
    if (!std.mem.eql(u8, &bytes, "*1\r\n$4\r\nPING\r\n")) return error.WrongHealthRequest;
    var writer = stream.writer(io, &.{});
    switch (mode) {
        .fragmented, .slow => {
            for ("+PONG\r\n") |byte| {
                try std.Io.sleep(io, .fromMilliseconds(if (mode == .slow) 250 else 10), .awake);
                writer.interface.writeByte(byte) catch |err| {
                    if (mode == .slow) return;
                    return err;
                };
            }
        },
        .silent => {},
        .eof => return,
        .short => {
            try writer.interface.writeAll("+PO");
            return;
        },
        .malformed => try writer.interface.writeAll("+PONG\n!"),
        .err => try writer.interface.writeAll("-ERR private peer text\r\n"),
        .bulk => try writer.interface.writeAll("$4\r\nPONG\r\n"),
        .integer => try writer.interface.writeAll(":1\r\n"),
    }
    // A success must return before EOF. Failures must also close the socket.
    _ = reader.interface.takeByte() catch |err| switch (err) {
        error.EndOfStream => return,
        error.ReadFailed => if (reader.err.? == error.ConnectionResetByPeer) return else return err,
    };
    return error.HealthConnectionLeftOpen;
}
