const std = @import("std");
const Config = @import("config.zig");

/// Directive names accepted in a kgcache.conf file, one per `Config` field.
const Directive = enum {
    bind,
    port,
    @"reuse-address",
    @"connection-buffer-size",
    @"num-databases",
    @"snapshot-path",
    @"active-expire-interval-ms",
    @"active-expire-budget-ms",
    @"active-expire-batch-size",
    @"active-expire-threshold-percent",
};

pub const Error = error{
    /// A non-blank, non-comment line didn't split into a directive and a value.
    MalformedLine,
    /// The first token on a line isn't one of the known `Directive`s.
    UnknownDirective,
    /// The value couldn't be parsed into the type the directive expects.
    InvalidValue,
};

/// blank lines and lines starting with `#` are skipped,
/// everything else must be `directive value`. Returns
/// `Config.default()` overlaid with whatever directives were present.
/// The returned `Config`'s string fields (`bind_address`, `snapshot_path`)
/// borrow directly from `contents`, so `contents` must outlive the `Config`.
pub fn parse(contents: []const u8) Error!Config {
    var config = Config.default();

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        const space = std.mem.indexOfAny(u8, line, " \t") orelse return Error.MalformedLine;
        const directive_name = line[0..space];
        const value = std.mem.trim(u8, line[space..], " \t");
        if (value.len == 0) return Error.MalformedLine;

        const directive = std.meta.stringToEnum(Directive, directive_name) orelse return Error.UnknownDirective;

        switch (directive) {
            .bind => config.bind_address = value,
            .port => config.port = try parseInt(u16, value),
            .@"reuse-address" => config.reuse_address = try parseBool(value),
            .@"connection-buffer-size" => config.connection_buffer_size = try parseInt(usize, value),
            .@"num-databases" => config.num_databases = try parseInt(usize, value),
            .@"snapshot-path" => config.snapshot_path = value,
            .@"active-expire-interval-ms" => config.active_expire_interval_ms = try parseInt(i64, value),
            .@"active-expire-budget-ms" => config.active_expire_budget_ms = try parseInt(i8, value),
            .@"active-expire-batch-size" => config.active_expire_batch_size = try parseInt(i8, value),
            .@"active-expire-threshold-percent" => config.active_expire_threshold_percent = try parseInt(i8, value),
        }
    }

    return config;
}

fn parseInt(comptime T: type, value: []const u8) Error!T {
    return std.fmt.parseInt(T, value, 10) catch Error.InvalidValue;
}

fn parseBool(value: []const u8) Error!bool {
    if (std.mem.eql(u8, value, "yes")) return true;
    if (std.mem.eql(u8, value, "no")) return false;
    return Error.InvalidValue;
}

test "parse overlays every directive onto the defaults" {
    const testing = std.testing;

    const contents =
        \\# kgcache.conf
        \\bind 0.0.0.0
        \\port 7000
        \\
        \\reuse-address no
        \\connection-buffer-size 2048
        \\num-databases 4
        \\snapshot-path /var/lib/kgcache/dump.kgc
        \\active-expire-interval-ms 250
        \\active-expire-budget-ms 20
        \\active-expire-batch-size 40
        \\active-expire-threshold-percent 50
    ;

    const config = try parse(contents);

    try testing.expectEqualStrings("0.0.0.0", config.bind_address);
    try testing.expectEqual(7000, config.port);
    try testing.expectEqual(false, config.reuse_address);
    try testing.expectEqual(2048, config.connection_buffer_size);
    try testing.expectEqual(4, config.num_databases);
    try testing.expectEqualStrings("/var/lib/kgcache/dump.kgc", config.snapshot_path);
    try testing.expectEqual(250, config.active_expire_interval_ms);
    try testing.expectEqual(20, config.active_expire_budget_ms);
    try testing.expectEqual(40, config.active_expire_batch_size);
    try testing.expectEqual(50, config.active_expire_threshold_percent);
}

test "parse leaves directives absent from a partial file at their defaults" {
    const testing = std.testing;

    const contents =
        \\port 7000
    ;

    const config = try parse(contents);
    const defaults = Config.default();

    try testing.expectEqual(7000, config.port);
    try testing.expectEqualStrings(defaults.bind_address, config.bind_address);
    try testing.expectEqual(defaults.reuse_address, config.reuse_address);
    try testing.expectEqual(defaults.connection_buffer_size, config.connection_buffer_size);
    try testing.expectEqual(defaults.num_databases, config.num_databases);
    try testing.expectEqualStrings(defaults.snapshot_path, config.snapshot_path);
    try testing.expectEqual(defaults.active_expire_interval_ms, config.active_expire_interval_ms);
    try testing.expectEqual(defaults.active_expire_budget_ms, config.active_expire_budget_ms);
    try testing.expectEqual(defaults.active_expire_batch_size, config.active_expire_batch_size);
    try testing.expectEqual(defaults.active_expire_threshold_percent, config.active_expire_threshold_percent);
}

test "parse rejects a line with a directive but no value" {
    const testing = std.testing;
    try testing.expectError(Error.MalformedLine, parse("port"));
}

test "parse rejects a directive name that isn't recognized" {
    const testing = std.testing;
    try testing.expectError(Error.UnknownDirective, parse("maxmemory 100mb"));
}

test "parse rejects a value that doesn't fit the directive's type" {
    const testing = std.testing;
    try testing.expectError(Error.InvalidValue, parse("port not-a-number"));
}

test "parse rejects a reuse-address value that isn't yes or no" {
    const testing = std.testing;
    try testing.expectError(Error.InvalidValue, parse("reuse-address maybe"));
}
