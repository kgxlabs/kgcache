const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const config_path = args.next() orelse return error.MissingConfigPath;
    if (!std.mem.eql(u8, args.next() orelse return error.MissingReadyFlag, "--ready-fd")) return error.MissingReadyFlag;
    const fd_text = args.next() orelse return error.MissingReadyFd;
    const fd = try std.fmt.parseInt(std.posix.fd_t, fd_text, 10);

    const config = try std.Io.Dir.cwd().readFileAlloc(init.io, config_path, init.gpa, .limited(4096));
    defer init.gpa.free(config);

    if (std.mem.indexOf(u8, config, "fake-mode empty\n") != null) {
        _ = std.c.close(fd);
        waitForever();
    }
    if (std.mem.indexOf(u8, config, "fake-mode assert\n") != null) {
        _ = std.c.write(2, "fake assertion\n", 15);
        return error.DeliberateAssertion;
    }
    if (std.mem.indexOf(u8, config, "fake-mode malformed\n") != null) {
        _ = std.c.write(fd, "NOT READY\n", 10);
        return;
    }
    if (std.mem.indexOf(u8, config, "fake-mode incomplete\n") != null) {
        _ = std.c.write(fd, "READY 127.0.0.1 43210", 21);
        return;
    }
    if (std.mem.indexOf(u8, config, "fake-mode flood\n") != null) {
        const line = "x" ** 4096;
        for (0..64) |_| {
            try writeAll(1, line);
            try writeAll(2, line);
        }
        _ = std.c.write(fd, "READY 127.0.0.1 43210\n", 22);
        waitForever();
    }
    if (std.mem.indexOf(u8, config, "fake-mode startup-timeout\n") != null) {
        _ = std.c.write(2, "fake startup hang\n", 18);
        waitForever();
    }
    if (std.mem.indexOf(u8, config, "fake-mode stop-timeout\n") != null) {
        const action = std.posix.Sigaction{
            .handler = .{ .handler = std.c.SIG.IGN },
            .mask = std.mem.zeroes(std.posix.sigset_t),
            .flags = 0,
        };
        std.posix.sigaction(.TERM, &action, null);
        _ = std.c.write(2, "fake shutdown hang\n", 19);
        _ = std.c.write(fd, "READY 127.0.0.1 43210\n", 22);
        waitForever();
    }
    return error.UnknownMode;
}

fn waitForever() noreturn {
    while (true) {
        var empty: [0]std.posix.pollfd = .{};
        _ = std.posix.poll(&empty, 1000) catch {};
    }
}

fn writeAll(fd: std.posix.fd_t, data: []const u8) !void {
    var remaining = data;
    while (remaining.len > 0) {
        const n = std.c.write(fd, remaining.ptr, remaining.len);
        if (n <= 0) return error.FakeWriteFailed;
        remaining = remaining[@intCast(n)..];
    }
}
