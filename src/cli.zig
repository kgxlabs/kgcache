const std = @import("std");
const registry = @import("config/registry.zig");
const directive_definition = @import("config/definition.zig");
const PreparedDirective = directive_definition.PreparedDirective;

const Cli = @This();

pub const Error = std.mem.Allocator.Error || directive_definition.ParseError || error{
    DuplicateReadyFd,
    MissingReadyFd,
    InvalidReadyFd,
    UnknownFlag,
    HealthcheckNotImplemented,
    DuplicateConfigPath,
};

allocator: std.mem.Allocator,
config_path: ?[]const u8 = null,
ready_fd: ?std.posix.fd_t = null,
overrides: std.ArrayList(PreparedDirective) = .empty,

/// Owns the ordered override list on success. Strings borrow argv bytes, which
/// must outlive both Cli and any Config built from its overrides.
/// On failure, frees all list storage without freeing borrowed argv bytes.
pub fn parse(allocator: std.mem.Allocator, process_args: std.process.Args) Error!Cli {
    var args = process_args.iterate();
    _ = args.skip();

    var values: std.ArrayList([]const u8) = .empty;
    defer values.deinit(allocator);
    while (args.next()) |arg| try values.append(allocator, arg);

    var cli: Cli = .{ .allocator = allocator };
    errdefer cli.deinit();
    var index: usize = 0;
    while (index < values.items.len) {
        const arg = values.items[index];
        // count directive name
        index += 1;

        if (std.mem.eql(u8, arg, "--ready-fd")) {
            if (cli.ready_fd != null) return error.DuplicateReadyFd;

            if (index == values.items.len) return error.MissingReadyFd;

            cli.ready_fd = try parseReadyFd(values.items[index]);
            index += 1;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            const definition = registry.find(arg[2..]) orelse return error.UnknownFlag;
            const remaining = values.items[index..];

            const count = if (definition.input.cli_value_count) |value_count|
                value_count(remaining)
            else
                definition.arity.minimum;

            if (count > remaining.len) return error.InvalidArity;

            const directive_values = remaining[0..count];
            // reject directive with no respective values
            for (directive_values) |value| {
                if (std.mem.startsWith(u8, value, "--")) return error.InvalidArity;
            }

            const prepared = try registry.prepare(definition, directive_values);
            try cli.overrides.append(allocator, prepared);

            // count directive values
            index += count;
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

/// Free only the prepared list. Config strings continue to borrow argv bytes.
pub fn deinit(self: *Cli) void {
    self.overrides.deinit(self.allocator);
    self.* = undefined;
}

fn parseReadyFd(value: []const u8) error{InvalidReadyFd}!std.posix.fd_t {
    if (value.len == 0) return error.InvalidReadyFd;
    for (value) |digit| {
        if (digit < '0' or digit > '9') return error.InvalidReadyFd;
    }
    const fd = std.fmt.parseInt(std.posix.fd_t, value, 10) catch return error.InvalidReadyFd;
    if (fd < 3) return error.InvalidReadyFd;
    return fd;
}

fn parseTestArgs(argv: []const [*:0]const u8) Error!Cli {
    return parse(std.testing.allocator, .{ .vector = argv });
}

test "CLI accepts default and config-path invocations" {
    const testing = std.testing;

    var defaults = try parseTestArgs(&.{"kgcache"});
    defer defaults.deinit();
    try testing.expect(defaults.config_path == null);
    try testing.expect(defaults.ready_fd == null);

    var with_config = try parseTestArgs(&.{ "kgcache", "cache.conf" });
    defer with_config.deinit();
    try testing.expectEqualStrings("cache.conf", with_config.config_path.?);
    try testing.expect(with_config.ready_fd == null);
}

test "CLI accepts a decimal readiness descriptor and optional config path" {
    const testing = std.testing;

    var ready_only = try parseTestArgs(&.{ "kgcache", "--ready-fd", "3" });
    defer ready_only.deinit();
    try testing.expectEqual(3, ready_only.ready_fd.?);
    try testing.expect(ready_only.config_path == null);

    var with_config = try parseTestArgs(&.{ "kgcache", "--ready-fd", "0042", "cache.conf" });
    defer with_config.deinit();
    try testing.expectEqual(42, with_config.ready_fd.?);
    try testing.expectEqualStrings("cache.conf", with_config.config_path.?);

    var config_first = try parseTestArgs(&.{ "kgcache", "cache.conf", "--ready-fd", "0042" });
    defer config_first.deinit();
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
        .{ error.InvalidArity, &.{ "kgcache", "--port" } },
        .{ error.InvalidArity, &.{ "kgcache", "--port", "--ready-fd", "3" } },
        .{ error.InvalidArity, &.{ "kgcache", "--save" } },
        .{ error.InvalidArity, &.{ "kgcache", "--save", "60" } },
        .{ error.InvalidArity, &.{ "kgcache", "--save", "60 1" } },
        .{ error.InvalidArity, &.{ "kgcache", "--save", "60", "--port", "7000" } },
        .{ error.InvalidValue, &.{ "kgcache", "--port", "-1" } },
        .{ error.InvalidValue, &.{ "kgcache", "--appendonly", "YES" } },
        .{ error.InvalidValue, &.{ "kgcache", "--dir", "" } },
        .{ error.InvalidValue, &.{ "kgcache", "--save", "0", "1" } },
        .{ error.UnknownFlag, &.{ "kgcache", "--Port", "7000" } },
        .{ error.UnknownFlag, &.{ "kgcache", "--port=7000" } },
        .{ error.UnknownFlag, &.{ "kgcache", "--port", "7000", "--save", "60", "1", "--unknown" } },
        .{ error.InvalidValue, &.{ "kgcache", "--port", "7000", "--port", "invalid" } },
        .{ error.InvalidReadyFd, &.{ "kgcache", "--save", "60", "1", "--ready-fd", "2" } },
        .{ error.DuplicateConfigPath, &.{ "kgcache", "one.conf", "--port", "7000", "two.conf" } },
    };

    inline for (cases) |case| {
        try testing.expectError(case[0], parseTestArgs(case[1]));
    }
}
