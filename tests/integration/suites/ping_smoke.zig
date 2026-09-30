const std = @import("std");

pub fn run(io: std.Io, allocator: std.mem.Allocator, executable_path: []const u8) !void {
    std.log.info("integration: PING smoke test started", .{});
    const cwd = std.Io.Dir.cwd();

    var random_bytes: [12]u8 = undefined;
    std.Io.random(io, &random_bytes);
    const suffix = std.fmt.bytesToHex(random_bytes, .lower);
    const temp_path = try std.fmt.allocPrint(allocator, "/tmp/kgcache-integration-{s}", .{suffix});
    defer allocator.free(temp_path);
    try cwd.createDir(io, temp_path, .default_dir);
    var temp_exists = true;
    defer {
        if (temp_exists) cwd.deleteTree(io, temp_path) catch {};
    }

    const config =
        \\bind 127.0.0.1
        \\port 0
        \\cron-interval-ms 20
        \\snapshot-path dump.kgc
        \\append-dirname aof
        \\append-filename appendonly.aof
    ;
    {
        const temp_dir = try cwd.openDir(io, temp_path, .{});
        defer temp_dir.close(io);
        try temp_dir.writeFile(io, .{ .sub_path = "kgcache.conf", .data = config });
    }

    var ready_fds: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&ready_fds) != 0) return error.PipeFailed;
    defer _ = std.c.close(ready_fds[0]);
    var ready_writer_open = true;
    defer {
        if (ready_writer_open) _ = std.c.close(ready_fds[1]);
    }

    var fd_buffer: [16]u8 = undefined;
    const ready_fd_arg = try std.fmt.bufPrint(&fd_buffer, "{d}", .{ready_fds[1]});
    var child = try std.process.spawn(io, .{
        .argv = &.{ executable_path, "kgcache.conf", "--ready-fd", ready_fd_arg },
        .cwd = .{ .path = temp_path },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer reapChild(&child, io);

    // we close the write fd because we dont need it
    _ = std.c.close(ready_fds[1]);
    ready_writer_open = false;

    const ready_file: std.Io.File = .{
        .handle = ready_fds[0],
        .flags = .{ .nonblocking = false },
    };
    var ready_buffer: [128]u8 = undefined;
    const ready_line = try readPipe(io, ready_file, &ready_buffer);
    const address = try parseReady(ready_line);

    const client = try address.connect(io, .{ .mode = .stream });
    {
        defer client.close(io);
        const request = "*1\r\n$4\r\nPING\r\n";
        // netWrite expects one data slice even when the header holds the full request.
        const written = try io.vtable.netWrite(io.userdata, client.socket.handle, request, &.{""}, 0);
        if (written != request.len) return error.ShortPingWrite;

        var reply: [7]u8 = undefined;
        var received: usize = 0;
        while (received < reply.len) {
            var read_slices = [_][]u8{reply[received..]};
            const n = try io.vtable.netRead(io.userdata, client.socket.handle, &read_slices);
            if (n == 0) return error.PrematureReplyEnd;
            received += n;
        }
        if (!std.mem.eql(u8, &reply, "+PONG\r\n")) return error.UnexpectedPingReply;
    }

    // this does not block. send SIGTERM which will be handled by server Signals' handler and let the destroy happen in the background
    try std.posix.kill(child.id.?, .TERM);

    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    const stdout = try readPipe(io, child.stdout.?, &stdout_buffer);
    const stderr = try readPipe(io, child.stderr.?, &stderr_buffer);

    const term = try child.wait(io);
    switch (term) {
        .exited => |status| if (status != 0) {
            std.log.err("kgcache exited {d}; stdout: {s}; stderr: {s}", .{ status, stdout, stderr });
            return error.UncleanShutdown;
        },
        else => {
            std.log.err("kgcache did not exit normally; stdout: {s}; stderr: {s}", .{ stdout, stderr });
            return error.UncleanShutdown;
        },
    }

    try cwd.deleteTree(io, temp_path);
    temp_exists = false;
    std.log.info("integration: PING smoke test passed", .{});
}

fn readPipe(io: std.Io, file: std.Io.File, buffer: []u8) ![]const u8 {
    var used: usize = 0;
    while (used < buffer.len) {
        const n = file.readStreaming(io, &.{buffer[used..]}) catch |err| switch (err) {
            error.EndOfStream => return buffer[0..used],
            else => return err,
        };
        if (n == 0) return buffer[0..used];
        used += n;
    }
    return error.PipeTooLong;
}

fn parseReady(line: []const u8) !std.Io.net.IpAddress {
    if (!std.mem.startsWith(u8, line, "READY ")) return error.MissingReady;

    if (line.len == 0 or line[line.len - 1] != '\n') return error.IncompleteReady;

    const payload = line[6 .. line.len - 1];
    const separator = std.mem.lastIndexOfScalar(u8, payload, ' ') orelse return error.MalformedReady;
    const host = payload[0..separator];

    if (!std.mem.eql(u8, host, "127.0.0.1")) return error.WrongReadyAddress;

    const port = std.fmt.parseInt(u16, payload[separator + 1 ..], 10) catch return error.MalformedReady;
    if (port == 0) return error.ZeroReadyPort;

    return std.Io.net.IpAddress.parseIp4(host, port);
}

fn reapChild(child: *std.process.Child, io: std.Io) void {
    if (child.id) |pid| {
        std.posix.kill(pid, .TERM) catch {};
        _ = child.wait(io) catch {
            child.kill(io);
            return;
        };
    }
}
