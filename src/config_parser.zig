const std = @import("std");
const Config = @import("config.zig");
const DirectiveDefinition = @import("config/definition.zig");

/// Directive names accepted in a kgcache.conf file, one per `Config` field.
const Directive = enum {
    bind,
    port,
    @"reuse-address",
    @"connection-buffer-size",
    databases,
    dir,
    dbfilename,
    @"cron-interval-ms",
    @"active-expire-budget-ms",
    @"active-expire-batch-size",
    @"active-expire-threshold-percent",
    @"exclusive-bg-persistence",
    save,
    appendonly,
    appendfsync,
    appenddirname,
    appendfilename,
    @"auto-aof-rewrite-percentage",
    @"auto-aof-rewrite-min-size",
    @"aof-load-truncated",
    @"bgsave-retry-delay-ms",
};

pub const Error = error{
    /// A line is missing a directive or value, or has an invalid value count.
    MalformedLine,
    /// The first token on a line isn't one of the known `Directive`s.
    UnknownDirective,
    /// The value couldn't be parsed or is outside the directive's valid range.
    InvalidValue,
    /// Allocating storage for a repeated directive's collected values failed.
    OutOfMemory,
};

/// blank lines and lines starting with `#` are skipped, everything else must be `directive value`.
/// Returns `Config.default()` overlaid with whatever directives were present.
///
/// The returned `Config`'s string fields borrow directly from `contents`,
/// so `contents` must outlive the `Config`.
/// `allocator` backs `Config.save_rules`, since a repeated `save` directive is
/// assembled line-by-line rather than borrowed as one contiguous slice of
/// `contents` -- pass the same arena used for the rest of `Config` so it's
/// freed the same way (server lifetime).
pub fn parse(allocator: std.mem.Allocator, contents: []const u8) Error!Config {
    var config = Config.default();
    var save_rules: std.ArrayList(Config.SaveRule) = .empty;
    errdefer save_rules.deinit(allocator);

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
            .port => config.port = try parseIntInRange(u16, value, 0, std.math.maxInt(u16)),
            .@"reuse-address" => config.reuse_address = try parseBool(value),
            .@"connection-buffer-size" => config.connection_buffer_size = try parseIntInRange(usize, value, 1, std.math.maxInt(usize)),
            .databases => config.num_databases = try parseIntInRange(usize, value, 1, std.math.maxInt(u32)),
            .dir => {
                try Config.validateDir(value);
                config.dir = value;
            },
            .dbfilename => {
                try Config.validateDbfilename(value);
                config.dbfilename = value;
            },
            .@"cron-interval-ms" => config.cron_interval_ms = try parseIntInRange(i64, value, 1, std.math.maxInt(i64)),
            .@"active-expire-budget-ms" => config.active_expire_budget_ms = try parseIntInRange(i8, value, 1, std.math.maxInt(i8)),
            .@"active-expire-batch-size" => config.active_expire_batch_size = try parseIntInRange(i8, value, 1, std.math.maxInt(i8)),
            .@"active-expire-threshold-percent" => config.active_expire_threshold_percent = try parseIntInRange(i8, value, 1, 100),
            .@"exclusive-bg-persistence" => config.exclusive_bg_persistence = try parseBool(value),
            .save => {
                var tokens = std.mem.tokenizeAny(u8, value, " \t");
                const seconds_str = tokens.next() orelse return mapParseError(error.InvalidArity);
                const changes_str = tokens.next() orelse return mapParseError(error.InvalidArity);
                if (tokens.next() != null) return mapParseError(error.InvalidArity);

                try save_rules.append(allocator, .{
                    .seconds = try parseIntInRange(i64, seconds_str, 1, std.math.maxInt(i64)),
                    .changes = try parseIntInRange(u32, changes_str, 1, std.math.maxInt(u32)),
                });
            },
            .appendonly => config.append_only = try parseBool(value),
            .appendfsync => config.append_fsync = try parseEnum(Config.AppendFsync, value),
            .appenddirname => {
                try Config.validateAppendDirname(value);
                config.append_dirname = value;
            },
            .appendfilename => config.append_filename = value,
            .@"auto-aof-rewrite-percentage" => config.auto_aof_rewrite_percentage = try parseInt(u32, value),
            .@"auto-aof-rewrite-min-size" => config.auto_aof_rewrite_min_size = try parseInt(usize, value),
            .@"aof-load-truncated" => config.aof_load_truncated = try parseBool(value),
            .@"bgsave-retry-delay-ms" => {
                const retry_delay_ms = try parseInt(i64, value);
                if (retry_delay_ms < 0) return Error.InvalidValue;
                config.bgsave_retry_delay_ms = retry_delay_ms;
            },
        }
    }

    config.save_rules = try save_rules.toOwnedSlice(allocator);
    return config;
}

fn mapParseError(err: DirectiveDefinition.ParseError) Error {
    return switch (err) {
        error.InvalidArity => Error.MalformedLine,
        error.InvalidValue => Error.InvalidValue,
    };
}

fn parseInt(comptime T: type, value: []const u8) Error!T {
    return std.fmt.parseInt(T, value, 10) catch mapParseError(error.InvalidValue);
}

fn parseIntInRange(comptime T: type, value: []const u8, min: T, max: T) Error!T {
    const parsed = try parseInt(T, value);
    if (parsed < min or parsed > max) return Error.InvalidValue;
    return parsed;
}

fn parseBool(value: []const u8) Error!bool {
    if (std.mem.eql(u8, value, "yes")) return true;
    if (std.mem.eql(u8, value, "no")) return false;
    return Error.InvalidValue;
}

fn parseEnum(comptime T: type, value: []const u8) Error!T {
    return std.meta.stringToEnum(T, value) orelse Error.InvalidValue;
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
        \\databases 4
        \\dir /var/lib/kgcache
        \\dbfilename custom.kgc
        \\cron-interval-ms 250
        \\active-expire-budget-ms 20
        \\active-expire-batch-size 40
        \\active-expire-threshold-percent 50
        \\bgsave-retry-delay-ms 10000
    ;

    const config = try parse(testing.allocator, contents);

    try testing.expectEqualStrings("0.0.0.0", config.bind_address);
    try testing.expectEqual(7000, config.port);
    try testing.expectEqual(false, config.reuse_address);
    try testing.expectEqual(2048, config.connection_buffer_size);
    try testing.expectEqual(4, config.num_databases);
    try testing.expectEqualStrings("/var/lib/kgcache", config.dir);
    try testing.expectEqualStrings("custom.kgc", config.dbfilename);
    try testing.expectEqual(250, config.cron_interval_ms);
    try testing.expectEqual(20, config.active_expire_budget_ms);
    try testing.expectEqual(40, config.active_expire_batch_size);
    try testing.expectEqual(50, config.active_expire_threshold_percent);
    try testing.expectEqual(10000, config.bgsave_retry_delay_ms);
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
    try testing.expectEqualStrings(defaults.dir, config.dir);
    try testing.expectEqualStrings(defaults.dbfilename, config.dbfilename);
    try testing.expectEqual(defaults.cron_interval_ms, config.cron_interval_ms);
    try testing.expectEqual(defaults.active_expire_budget_ms, config.active_expire_budget_ms);
    try testing.expectEqual(defaults.active_expire_batch_size, config.active_expire_batch_size);
    try testing.expectEqual(defaults.active_expire_threshold_percent, config.active_expire_threshold_percent);
    try testing.expectEqual(defaults.bgsave_retry_delay_ms, config.bgsave_retry_delay_ms);
}

test "parse rejects a negative bgsave retry delay" {
    const testing = std.testing;
    try testing.expectError(Error.InvalidValue, parse(testing.allocator, "bgsave-retry-delay-ms -1"));
}

test "parse enforces numeric directive boundaries" {
    const testing = std.testing;
    const cases = [_]struct {
        minimum: []const u8,
        maximum: []const u8,
        below_minimum: []const u8,
        above_maximum: []const u8,
    }{
        .{ .minimum = "port 0", .maximum = "port 65535", .below_minimum = "port -1", .above_maximum = "port 65536" },
        .{ .minimum = "databases 1", .maximum = "databases 4294967295", .below_minimum = "databases 0", .above_maximum = "databases 4294967296" },
        .{ .minimum = "cron-interval-ms 1", .maximum = "cron-interval-ms 9223372036854775807", .below_minimum = "cron-interval-ms 0", .above_maximum = "cron-interval-ms 9223372036854775808" },
        .{ .minimum = "active-expire-budget-ms 1", .maximum = "active-expire-budget-ms 127", .below_minimum = "active-expire-budget-ms 0", .above_maximum = "active-expire-budget-ms 128" },
        .{ .minimum = "active-expire-batch-size 1", .maximum = "active-expire-batch-size 127", .below_minimum = "active-expire-batch-size 0", .above_maximum = "active-expire-batch-size 128" },
        .{ .minimum = "active-expire-threshold-percent 1", .maximum = "active-expire-threshold-percent 100", .below_minimum = "active-expire-threshold-percent 0", .above_maximum = "active-expire-threshold-percent 101" },
    };

    for (cases) |case| {
        for ([_][]const u8{ case.minimum, case.maximum }) |line| {
            const config = try parse(testing.allocator, line);
            testing.allocator.free(config.save_rules);
        }
        for ([_][]const u8{ case.below_minimum, case.above_maximum }) |line| {
            try testing.expectError(Error.InvalidValue, parse(testing.allocator, line));
        }
    }

    const max_buffer_size = try std.fmt.allocPrint(testing.allocator, "connection-buffer-size {d}", .{std.math.maxInt(usize)});
    defer testing.allocator.free(max_buffer_size);
    const above_max_buffer_size = try std.fmt.allocPrint(testing.allocator, "connection-buffer-size {d}", .{@as(u128, std.math.maxInt(usize)) + 1});
    defer testing.allocator.free(above_max_buffer_size);

    for ([_][]const u8{ "connection-buffer-size 1", max_buffer_size }) |line| {
        const config = try parse(testing.allocator, line);
        testing.allocator.free(config.save_rules);
    }
    for ([_][]const u8{ "connection-buffer-size 0", above_max_buffer_size }) |line| {
        try testing.expectError(Error.InvalidValue, parse(testing.allocator, line));
    }
}

test "parse accepts port zero for an OS-selected listener" {
    const testing = std.testing;
    const config = try parse(testing.allocator, "port 0");
    defer testing.allocator.free(config.save_rules);
    try testing.expectEqual(0, config.port);
}

test "parse preserves zero controls and their upper boundaries" {
    const testing = std.testing;
    const config = try parse(
        testing.allocator,
        "auto-aof-rewrite-percentage 0\nbgsave-retry-delay-ms 0",
    );
    defer testing.allocator.free(config.save_rules);
    try testing.expectEqual(0, config.auto_aof_rewrite_percentage);
    try testing.expectEqual(0, config.bgsave_retry_delay_ms);

    for ([_][]const u8{
        "auto-aof-rewrite-percentage 4294967295",
        "bgsave-retry-delay-ms 9223372036854775807",
    }) |line| {
        const boundary = try parse(testing.allocator, line);
        testing.allocator.free(boundary.save_rules);
    }
    for ([_][]const u8{
        "auto-aof-rewrite-percentage -1",
        "auto-aof-rewrite-percentage 4294967296",
        "bgsave-retry-delay-ms 9223372036854775808",
    }) |line| {
        try testing.expectError(Error.InvalidValue, parse(testing.allocator, line));
    }
}

test "parse accepts zero and the type limit for minimum AOF rewrite size" {
    const testing = std.testing;
    const max_size = try std.fmt.allocPrint(testing.allocator, "auto-aof-rewrite-min-size {d}", .{std.math.maxInt(usize)});
    defer testing.allocator.free(max_size);
    const above_max_size = try std.fmt.allocPrint(testing.allocator, "auto-aof-rewrite-min-size {d}", .{@as(u128, std.math.maxInt(usize)) + 1});
    defer testing.allocator.free(above_max_size);

    for ([_][]const u8{ "auto-aof-rewrite-min-size 0", max_size }) |line| {
        const config = try parse(testing.allocator, line);
        testing.allocator.free(config.save_rules);
    }
    try testing.expectError(Error.InvalidValue, parse(testing.allocator, above_max_size));
}

test "parse rejects a line with a directive but no value" {
    const testing = std.testing;
    try testing.expectError(Error.MalformedLine, parse(testing.allocator, "port"));
}

test "parse rejects a directive name that isn't recognized" {
    const testing = std.testing;
    try testing.expectError(Error.UnknownDirective, parse(testing.allocator, "maxmemory 100mb"));
}

test "parse rejects removed database and AOF directive names" {
    const testing = std.testing;
    for ([_][]const u8{
        "num-databases 4",
        "append-dirname appendonlydir",
        "append-filename appendonly.aof",
    }) |contents| {
        try testing.expectError(Error.UnknownDirective, parse(testing.allocator, contents));
    }
}

test "parse uses the last value for repeated database and AOF settings" {
    const testing = std.testing;
    const contents =
        \\databases 4
        \\appenddirname first-aof
        \\appendfilename first.aof
        \\databases 8
        \\appenddirname second-aof
        \\appendfilename second.aof
    ;

    const config = try parse(testing.allocator, contents);
    defer testing.allocator.free(config.save_rules);

    try testing.expectEqual(8, config.num_databases);
    try testing.expectEqualStrings("second-aof", config.append_dirname);
    try testing.expectEqualStrings("second.aof", config.append_filename);
}

test "parse uses the last dir and dbfilename values" {
    const testing = std.testing;
    const contents =
        \\dir ./first
        \\dbfilename first.kgc
        \\dir ./second
        \\dbfilename second.kgc
    ;

    const config = try parse(testing.allocator, contents);
    defer testing.allocator.free(config.save_rules);

    try testing.expectEqualStrings("./second", config.dir);
    try testing.expectEqualStrings("second.kgc", config.dbfilename);
}

test "parse rejects the removed snapshot-path directive" {
    const testing = std.testing;
    try testing.expectError(Error.UnknownDirective, parse(testing.allocator, "snapshot-path dump.kgc"));
}

test "parse requires a snapshot basename ending in kgc" {
    const testing = std.testing;
    for ([_][]const u8{
        "dbfilename dump.rdb",
        "dbfilename /absolute/path/dump.kgc",
        "dbfilename data/dump.kgc",
        "dbfilename ../dump.kgc",
        "dbfilename data\\dump.kgc",
        "dbfilename dump\x00.kgc",
    }) |contents| {
        try testing.expectError(Error.InvalidValue, parse(testing.allocator, contents));
    }
}

test "parse requires an AOF directory name within dir" {
    const testing = std.testing;
    for ([_][]const u8{
        "appenddirname .",
        "appenddirname ..",
        "appenddirname /absolute/path/aof",
        "appenddirname data/aof",
        "appenddirname ../aof",
        "appenddirname data\\aof",
        "appenddirname aof\x00dir",
    }) |contents| {
        try testing.expectError(Error.InvalidValue, parse(testing.allocator, contents));
    }
}

test "parse rejects persistence directives without values" {
    const testing = std.testing;
    for ([_][]const u8{ "dir", "dbfilename", "appenddirname" }) |contents| {
        try testing.expectError(Error.MalformedLine, parse(testing.allocator, contents));
    }
}

test "parse validates every occurrence of persistence settings" {
    const testing = std.testing;
    for ([_][]const u8{
        "dir data\x00dir\ndir ./data",
        "dbfilename dump.rdb\ndbfilename dump.kgc",
        "appenddirname ../aof\nappenddirname aof",
    }) |contents| {
        try testing.expectError(Error.InvalidValue, parse(testing.allocator, contents));
    }
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

test "parse enforces both save rule boundaries" {
    const testing = std.testing;
    for ([_][]const u8{
        "save 1 1",
        "save 9223372036854775807 4294967295",
    }) |line| {
        const config = try parse(testing.allocator, line);
        defer testing.allocator.free(config.save_rules);
        try testing.expectEqual(1, config.save_rules.len);
    }
    for ([_][]const u8{
        "save 0 1",
        "save -1 1",
        "save 9223372036854775808 1",
        "save 1 0",
        "save 1 4294967296",
    }) |line| {
        try testing.expectError(Error.InvalidValue, parse(testing.allocator, line));
    }
}

test "parse frees collected save rules if a later directive is invalid" {
    const testing = std.testing;
    try testing.expectError(
        Error.InvalidValue,
        parse(testing.allocator, "save 300 100\nport invalid"),
    );
}

test "parse reads every aof directive" {
    const testing = std.testing;

    const contents =
        \\appendonly yes
        \\appendfsync always
        \\appenddirname custom-aof
        \\appendfilename myappendonly.aof
        \\auto-aof-rewrite-percentage 50
        \\auto-aof-rewrite-min-size 1024
        \\aof-load-truncated no
    ;

    const config = try parse(testing.allocator, contents);
    defer testing.allocator.free(config.save_rules);

    try testing.expectEqual(true, config.append_only);
    try testing.expectEqual(Config.AppendFsync.always, config.append_fsync);
    try testing.expectEqualStrings("custom-aof", config.append_dirname);
    try testing.expectEqualStrings("myappendonly.aof", config.append_filename);
    try testing.expectEqual(50, config.auto_aof_rewrite_percentage);
    try testing.expectEqual(1024, config.auto_aof_rewrite_min_size);
    try testing.expectEqual(false, config.aof_load_truncated);
}

test "parse defaults aof off with everysec fsync when no aof directive is present" {
    const testing = std.testing;

    const config = try parse(testing.allocator, "port 7000");
    defer testing.allocator.free(config.save_rules);
    const defaults = Config.default();

    try testing.expectEqual(defaults.append_only, config.append_only);
    try testing.expectEqual(false, config.append_only);
    try testing.expectEqual(Config.AppendFsync.everysec, config.append_fsync);
    try testing.expectEqualStrings(defaults.append_filename, config.append_filename);
    try testing.expectEqualStrings(defaults.append_dirname, config.append_dirname);
    try testing.expectEqual(defaults.auto_aof_rewrite_percentage, config.auto_aof_rewrite_percentage);
    try testing.expectEqual(defaults.auto_aof_rewrite_min_size, config.auto_aof_rewrite_min_size);
    try testing.expectEqual(defaults.aof_load_truncated, config.aof_load_truncated);
}

test "parse accepts each appendfsync value" {
    const testing = std.testing;

    {
        const config = try parse(testing.allocator, "appendfsync always");
        defer testing.allocator.free(config.save_rules);
        try testing.expectEqual(Config.AppendFsync.always, config.append_fsync);
    }
    {
        const config = try parse(testing.allocator, "appendfsync everysec");
        defer testing.allocator.free(config.save_rules);
        try testing.expectEqual(Config.AppendFsync.everysec, config.append_fsync);
    }
    {
        const config = try parse(testing.allocator, "appendfsync no");
        defer testing.allocator.free(config.save_rules);
        try testing.expectEqual(Config.AppendFsync.no, config.append_fsync);
    }
}

test "parse rejects an appendfsync value that isn't one of the three" {
    const testing = std.testing;
    try testing.expectError(Error.InvalidValue, parse(testing.allocator, "appendfsync maybe"));
}

test "parse rejects a non-numeric auto-aof-rewrite-percentage" {
    const testing = std.testing;
    try testing.expectError(Error.InvalidValue, parse(testing.allocator, "auto-aof-rewrite-percentage many"));
}

test "parse rejects a size suffix in auto-aof-rewrite-min-size" {
    const testing = std.testing;
    try testing.expectError(Error.InvalidValue, parse(testing.allocator, "auto-aof-rewrite-min-size 64mb"));
}
