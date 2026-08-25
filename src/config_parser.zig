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
    @"cron-interval-ms",
    @"active-expire-budget-ms",
    @"active-expire-batch-size",
    @"active-expire-threshold-percent",
    @"exclusive-bg-persistence",
    save,
};

pub const Error = error{
    /// A non-blank, non-comment line didn't split into a directive and a value.
    MalformedLine,
    /// The first token on a line isn't one of the known `Directive`s.
    UnknownDirective,
    /// The value couldn't be parsed into the type the directive expects.
    InvalidValue,
    /// Allocating storage for a repeated directive's collected values failed.
    OutOfMemory,
};

/// blank lines and lines starting with `#` are skipped, everything else must be `directive value`.
/// Returns `Config.default()` overlaid with whatever directives were present.
///
/// The returned `Config`'s string fields (`bind_address`, `snapshot_path`) borrow directly from `contents`, so `contents` must outlive the `Config`.
/// `allocator` backs `Config.save_rules`, since a repeated `save` directive is
/// assembled line-by-line rather than borrowed as one contiguous slice of
/// `contents` -- pass the same arena used for the rest of `Config` so it's
/// freed the same way (server lifetime).
pub fn parse(allocator: std.mem.Allocator, contents: []const u8) Error!Config {
    var config = Config.default();
    var save_rules: std.ArrayList(Config.SaveRule) = .empty;

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
            .@"cron-interval-ms" => config.cron_interval_ms = try parseInt(i64, value),
            .@"active-expire-budget-ms" => config.active_expire_budget_ms = try parseInt(i8, value),
            .@"active-expire-batch-size" => config.active_expire_batch_size = try parseInt(i8, value),
            .@"active-expire-threshold-percent" => config.active_expire_threshold_percent = try parseInt(i8, value),
            .@"exclusive-bg-persistence" => config.exclusive_bg_persistence = try parseBool(value),
            .save => {
                var tokens = std.mem.tokenizeAny(u8, value, " \t");
                const seconds_str = tokens.next() orelse return Error.MalformedLine;
                const changes_str = tokens.next() orelse return Error.MalformedLine;
                if (tokens.next() != null) return Error.MalformedLine;

                save_rules.append(allocator, .{
                    .seconds = try parseInt(i64, seconds_str),
                    .changes = try parseInt(u32, changes_str),
                }) catch return Error.OutOfMemory;
            },
        }
    }

    config.save_rules = save_rules.toOwnedSlice(allocator) catch return Error.OutOfMemory;
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
        \\cron-interval-ms 250
        \\active-expire-budget-ms 20
        \\active-expire-batch-size 40
        \\active-expire-threshold-percent 50
    ;

    const config = try parse(testing.allocator, contents);

    try testing.expectEqualStrings("0.0.0.0", config.bind_address);
    try testing.expectEqual(7000, config.port);
    try testing.expectEqual(false, config.reuse_address);
    try testing.expectEqual(2048, config.connection_buffer_size);
    try testing.expectEqual(4, config.num_databases);
    try testing.expectEqualStrings("/var/lib/kgcache/dump.kgc", config.snapshot_path);
    try testing.expectEqual(250, config.cron_interval_ms);
    try testing.expectEqual(20, config.active_expire_budget_ms);
    try testing.expectEqual(40, config.active_expire_batch_size);
    try testing.expectEqual(50, config.active_expire_threshold_percent);
}

test "parse leaves directives absent from a partial file at their defaults" {
    const testing = std.testing;

    const contents =
        \\port 7000
    ;

    const config = try parse(testing.allocator, contents);
    const defaults = Config.default();

    try testing.expectEqual(7000, config.port);
    try testing.expectEqualStrings(defaults.bind_address, config.bind_address);
    try testing.expectEqual(defaults.reuse_address, config.reuse_address);
    try testing.expectEqual(defaults.connection_buffer_size, config.connection_buffer_size);
    try testing.expectEqual(defaults.num_databases, config.num_databases);
    try testing.expectEqualStrings(defaults.snapshot_path, config.snapshot_path);
    try testing.expectEqual(defaults.cron_interval_ms, config.cron_interval_ms);
    try testing.expectEqual(defaults.active_expire_budget_ms, config.active_expire_budget_ms);
    try testing.expectEqual(defaults.active_expire_batch_size, config.active_expire_batch_size);
    try testing.expectEqual(defaults.active_expire_threshold_percent, config.active_expire_threshold_percent);
}

test "parse rejects a line with a directive but no value" {
    const testing = std.testing;
    try testing.expectError(Error.MalformedLine, parse(testing.allocator, "port"));
}

test "parse rejects a directive name that isn't recognized" {
    const testing = std.testing;
    try testing.expectError(Error.UnknownDirective, parse(testing.allocator, "maxmemory 100mb"));
}

test "parse rejects a value that doesn't fit the directive's type" {
    const testing = std.testing;
    try testing.expectError(Error.InvalidValue, parse(testing.allocator, "port not-a-number"));
}

test "parse rejects a reuse-address value that isn't yes or no" {
    const testing = std.testing;
    try testing.expectError(Error.InvalidValue, parse(testing.allocator, "reuse-address maybe"));
}

test "parse accepts a single save rule" {
    const testing = std.testing;

    const config = try parse(testing.allocator, "save 300 100");
    defer testing.allocator.free(config.save_rules);

    try testing.expectEqual(1, config.save_rules.len);
    try testing.expectEqual(300, config.save_rules[0].seconds);
    try testing.expectEqual(100, config.save_rules[0].changes);
}

test "parse accepts multiple save lines and keeps all of them" {
    const testing = std.testing;

    const contents =
        \\save 900 1
        \\save 300 10
        \\save 60 10000
    ;
    const config = try parse(testing.allocator, contents);
    defer testing.allocator.free(config.save_rules);

    try testing.expectEqual(3, config.save_rules.len);
    try testing.expectEqual(900, config.save_rules[0].seconds);
    try testing.expectEqual(1, config.save_rules[0].changes);
    try testing.expectEqual(300, config.save_rules[1].seconds);
    try testing.expectEqual(10, config.save_rules[1].changes);
    try testing.expectEqual(60, config.save_rules[2].seconds);
    try testing.expectEqual(10000, config.save_rules[2].changes);
}

test "parse defaults to no save rules when the directive is absent" {
    const testing = std.testing;

    const config = try parse(testing.allocator, "port 7000");
    defer testing.allocator.free(config.save_rules);

    try testing.expectEqual(0, config.save_rules.len);
}

test "parse rejects a save line with only one value" {
    const testing = std.testing;
    try testing.expectError(Error.MalformedLine, parse(testing.allocator, "save 300"));
}

test "parse rejects a save line with more than two values" {
    const testing = std.testing;
    try testing.expectError(Error.MalformedLine, parse(testing.allocator, "save 300 100 200"));
}

test "parse rejects a save line with a non-numeric value" {
    const testing = std.testing;
    try testing.expectError(Error.InvalidValue, parse(testing.allocator, "save 300 many"));
}
