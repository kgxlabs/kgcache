const std = @import("std");

const Cli = @This();

config_path: ?[]const u8 = null,
ready_fd: ?std.posix.fd_t = null,

pub fn parse(process_args: std.process.Args) !Cli {
    var args = process_args.iterate();
    _ = args.skip();

    var cli: Cli = .{};
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--ready-fd")) {
            if (cli.ready_fd != null) return error.DuplicateReadyFd;
            const value = args.next() orelse return error.MissingReadyFd;
            cli.ready_fd = try parseReadyFd(value);
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownFlag;
        } else if (std.mem.eql(u8, arg, "healthcheck")) {
            return error.HealthcheckNotImplemented;
        } else if (cli.config_path != null) {
            return error.DuplicateConfigPath;
        } else {
            cli.config_path = arg;
        }
    }
    return cli;
}

fn parseReadyFd(value: []const u8) !std.posix.fd_t {
    if (value.len == 0) return error.InvalidReadyFd;
    for (value) |digit| {
        if (digit < '0' or digit > '9') return error.InvalidReadyFd;
    }
    const fd = std.fmt.parseInt(std.posix.fd_t, value, 10) catch return error.InvalidReadyFd;
    if (fd < 3) return error.InvalidReadyFd;
    return fd;
}

fn parseTestArgs(argv: []const [*:0]const u8) !Cli {
    return parse(.{ .vector = argv });
}

test "CLI accepts default and config-path invocations" {
    const testing = std.testing;

    const defaults = try parseTestArgs(&.{"kgcache"});
    try testing.expect(defaults.config_path == null);
    try testing.expect(defaults.ready_fd == null);

    const with_config = try parseTestArgs(&.{ "kgcache", "cache.conf" });
    try testing.expectEqualStrings("cache.conf", with_config.config_path.?);
    try testing.expect(with_config.ready_fd == null);
}

test "CLI accepts a decimal readiness descriptor and optional config path" {
    const testing = std.testing;

    const ready_only = try parseTestArgs(&.{ "kgcache", "--ready-fd", "3" });
    try testing.expectEqual(3, ready_only.ready_fd.?);
    try testing.expect(ready_only.config_path == null);

    const with_config = try parseTestArgs(&.{ "kgcache", "--ready-fd", "0042", "cache.conf" });
    try testing.expectEqual(42, with_config.ready_fd.?);
    try testing.expectEqualStrings("cache.conf", with_config.config_path.?);

    const config_first = try parseTestArgs(&.{ "kgcache", "cache.conf", "--ready-fd", "0042" });
    try testing.expectEqual(with_config.ready_fd.?, config_first.ready_fd.?);
    try testing.expectEqualStrings(with_config.config_path.?, config_first.config_path.?);
}

test "CLI rejects invalid argument shapes" {
    const testing = std.testing;
    const cases = .{
        .{ error.UnknownFlag, &.{ "kgcache", "--unknown" } },
        .{ error.UnknownFlag, &.{ "kgcache", "-x" } },
        .{ error.DuplicateConfigPath, &.{ "kgcache", "one.conf", "two.conf" } },
        .{ error.MissingReadyFd, &.{ "kgcache", "--ready-fd" } },
        .{ error.InvalidReadyFd, &.{ "kgcache", "--ready-fd", "abc" } },
        .{ error.InvalidReadyFd, &.{ "kgcache", "--ready-fd", "2x" } },
        .{ error.InvalidReadyFd, &.{ "kgcache", "--ready-fd", "+3" } },
        .{ error.InvalidReadyFd, &.{ "kgcache", "--ready-fd", "-3" } },
        .{ error.InvalidReadyFd, &.{ "kgcache", "--ready-fd", "2147483648" } },
        .{ error.InvalidReadyFd, &.{ "kgcache", "--ready-fd", "0" } },
        .{ error.InvalidReadyFd, &.{ "kgcache", "--ready-fd", "2" } },
        .{ error.DuplicateReadyFd, &.{ "kgcache", "--ready-fd", "3", "--ready-fd", "4" } },
        .{ error.DuplicateConfigPath, &.{ "kgcache", "--ready-fd", "3", "one.conf", "two.conf" } },
        .{ error.DuplicateReadyFd, &.{ "kgcache", "one.conf", "--ready-fd", "3", "--ready-fd", "4" } },
        .{ error.HealthcheckNotImplemented, &.{ "kgcache", "healthcheck" } },
    };

    inline for (cases) |case| {
        try testing.expectError(case[0], parseTestArgs(case[1]));
    }
}
