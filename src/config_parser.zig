//! Apply file syntax through registry preparation and builder application.
//! Blank lines and full-line comments are skipped; quotes and inline # stay literal.

const std = @import("std");
const Config = @import("config.zig");
const ConfigBuilder = @import("config/builder.zig");
const registry = @import("config/registry.zig");
const directive_definition = @import("config/definition.zig");

pub const Error = error{
    /// A line is missing a directive or value, or has an invalid value count.
    MalformedLine,
    /// The first token on a line isn't a supported directive name.
    UnknownDirective,
    /// The value couldn't be parsed or is outside the directive's valid range.
    InvalidValue,
    /// Allocating parsing or builder storage failed.
    OutOfMemory,
};

/// Start a builder, apply this file, finish once, and always clean up temporary state.
/// Returned strings borrow contents, which must remain alive while Config is used.
/// The caller owns allocated save_rules: free with allocator or release its arena.
/// On failure, builder-owned output and temporary token storage are freed.
pub fn parse(allocator: std.mem.Allocator, contents: []const u8) Error!Config {
    var builder = ConfigBuilder.init(allocator);
    defer builder.deinit();

    try apply(&builder, contents);
    return builder.finish();
}

/// Apply to an existing builder; the caller finishes once and always calls deinit.
/// Keep contents alive for borrowed Config strings; temporary tokens are freed on exit.
/// Invalid arity maps to MalformedLine. Any file error ends the build.
pub fn apply(builder: *ConfigBuilder, contents: []const u8) Error!void {
    std.debug.assert(builder.status == .building);
    errdefer builder.status = .failed;

    // Reuse the slice array across token-based lines. Values borrow contents,
    // not this array; preparation copies save numbers before the array is cleared.
    var token_values: std.ArrayList([]const u8) = .empty;
    defer token_values.deinit(builder.allocator);

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        const space = std.mem.indexOfAny(u8, line, " \t") orelse return Error.MalformedLine;
        const directive_name = line[0..space];
        const value = std.mem.trim(u8, line[space..], " \t");
        if (value.len == 0) return Error.MalformedLine;

        const definition = registry.find(directive_name) orelse return Error.UnknownDirective;
        const unsplit_value = [_][]const u8{value};
        const values: []const []const u8 = switch (definition.input.file_values) {
            .unsplit_value => &unsplit_value,
            .tokens => blk: {
                token_values.clearRetainingCapacity();

                var tokens = std.mem.tokenizeAny(u8, value, " \t");
                while (tokens.next()) |token| try token_values.append(builder.allocator, token);
                break :blk token_values.items;
            },
        };

        const prepared = registry.prepare(
            definition,
            values,
        ) catch |err| return mapParseError(err);
        try builder.apply(prepared, .file);
    }
}

fn mapParseError(err: directive_definition.ParseError) Error {
    return switch (err) {
        error.InvalidArity => Error.MalformedLine,
        error.InvalidValue => Error.InvalidValue,
    };
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

test "apply adds file contents to an existing builder without finishing it" {
    const testing = std.testing;
    const config = blk: {
        var builder = ConfigBuilder.init(testing.allocator);
        defer builder.deinit();
        try builder.apply(try registry.prepare(registry.find("port").?, &.{"8000"}), .file);
        try builder.apply(try registry.prepare(registry.find("appendonly").?, &.{"yes"}), .file);
        try builder.apply(try registry.prepare(registry.find("save").?, &.{ "900", "1" }), .file);

        try apply(&builder, "port 7000\ndir data files\nsave 60 1");
        try apply(&builder, " \t# nothing to apply\r\n\r\n");
        try apply(&builder, "save 300 10\nappendfsync always");
        try testing.expectEqual(.building, builder.status);
        try testing.expectEqual(1, builder.states.items.len);
        try testing.expectEqual(0, builder.config.save_rules.len);
        break :blk try builder.finish();
    };
    defer testing.allocator.free(config.save_rules);
    var expected = Config.default();
    expected.port = 7000;
    expected.dir = "data files";
    expected.append_only = true;
    expected.append_fsync = .always;
    expected.save_rules = &.{
        .{ .seconds = 900, .changes = 1 },
        .{ .seconds = 60, .changes = 1 },
        .{ .seconds = 300, .changes = 10 },
    };
    try testing.expectEqualDeep(expected, config);
}

test "apply failure leaves builder cleanup with its caller" {
    const testing = std.testing;
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    {
        var builder = ConfigBuilder.init(failing.allocator());
        defer builder.deinit();
        try testing.expectError(
            Error.InvalidValue,
            apply(&builder, "port 7000\nsave 60 1\nsave 300 invalid"),
        );
        try testing.expectEqual(.failed, builder.status);
        try testing.expectEqual(7000, builder.config.port);
        try testing.expectEqual(0, builder.config.save_rules.len);
        try testing.expectEqual(1, builder.states.items.len);
        try testing.expect(failing.allocated_bytes > failing.freed_bytes);
    }
    try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

test "parse returns defaults for empty and comment-only files without allocation" {
    for ([_][]const u8{ "", " \t\r\n\n\t# comment\r\n# another comment" }) |contents| {
        const config = try parse(std.testing.failing_allocator, contents);
        try std.testing.expectEqualDeep(Config.default(), config);
    }
}

test "parse builds all 21 directive fields through the registry" {
    const testing = std.testing;
    const contents =
        \\bind example host
        \\port 7000
        \\reuse-address no
        \\connection-buffer-size 2048
        \\databases 4
        \\dir data files
        \\dbfilename state.kgc
        \\cron-interval-ms 250
        \\active-expire-budget-ms 15
        \\active-expire-batch-size 30
        \\active-expire-threshold-percent 50
        \\exclusive-bg-persistence no
        \\save 60 1
        \\save 300 10
        \\appendonly yes
        \\appendfsync always
        \\appenddirname history
        \\appendfilename history/journal.aof
        \\auto-aof-rewrite-percentage 0
        \\auto-aof-rewrite-min-size 2048
        \\aof-load-truncated no
        \\bgsave-retry-delay-ms 0
    ;
    const config = try parse(testing.allocator, contents);
    defer testing.allocator.free(config.save_rules);
    const expected: Config = .{
        .bind_address = "example host",
        .port = 7000,
        .reuse_address = false,
        .connection_buffer_size = 2048,
        .num_databases = 4,
        .dir = "data files",
        .dbfilename = "state.kgc",
        .cron_interval_ms = 250,
        .active_expire_budget_ms = 15,
        .active_expire_batch_size = 30,
        .active_expire_threshold_percent = 50,
        .exclusive_bg_persistence = false,
        .save_rules = &.{
            .{ .seconds = 60, .changes = 1 },
            .{ .seconds = 300, .changes = 10 },
        },
        .append_only = true,
        .append_fsync = .always,
        .append_dirname = "history",
        .append_filename = "history/journal.aof",
        .auto_aof_rewrite_percentage = 0,
        .auto_aof_rewrite_min_size = 2048,
        .aof_load_truncated = false,
        .bgsave_retry_delay_ms = 0,
    };
    try testing.expectEqualDeep(expected, config);
}

test "parse preserves file whitespace, literal quotes, and borrowed strings" {
    const testing = std.testing;
    var contents = (" \t# full-line comment\r\n \t\r\n\tport\t7000 \r\n" ++
        " dir\t \"data\tfiles\" \r\n bind example host # literal\r\n" ++
        "save\t60\t1\r\nsave  300\t10").*;
    const config = try parse(testing.allocator, &contents);
    defer testing.allocator.free(config.save_rules);
    try testing.expectEqual(7000, config.port);
    try testing.expectEqualStrings("\"data\tfiles\"", config.dir);
    try testing.expectEqualStrings("example host # literal", config.bind_address);
    try testing.expectEqualDeep(&[_]Config.SaveRule{
        .{ .seconds = 60, .changes = 1 },
        .{ .seconds = 300, .changes = 10 },
    }, config.save_rules);
    const directory_offset = std.mem.indexOf(u8, &contents, "\"data\tfiles\"").?;
    try testing.expect(config.dir.ptr == contents[directory_offset..].ptr);
    contents[directory_offset + 1] = 'D';
    try testing.expectEqualStrings("\"Data\tfiles\"", config.dir);

    const quoted_empty = try parse(testing.failing_allocator, "dir \"\"");
    try testing.expectEqualStrings("\"\"", quoted_empty.dir);
}

test "parse preserves arity, value, and name errors for every occurrence" {
    const testing = std.testing;
    for ([_]struct { contents: []const u8, err: Error }{
        .{ .contents = "port \t\r\n", .err = Error.MalformedLine },
        .{ .contents = "unknown", .err = Error.MalformedLine },
        .{ .contents = "save \"\"", .err = Error.MalformedLine },
        .{ .contents = "save 60 1 " ++ ("extra " ** 24), .err = Error.MalformedLine },
        .{ .contents = "port 7000 extra", .err = Error.InvalidValue },
        .{ .contents = "port 7000 # inline", .err = Error.InvalidValue },
        .{ .contents = "port \"7000\"", .err = Error.InvalidValue },
        .{ .contents = "appendonly \"yes\"", .err = Error.InvalidValue },
        .{ .contents = "appendfsync \"always\"", .err = Error.InvalidValue },
        .{ .contents = "port invalid\nport 7000", .err = Error.InvalidValue },
        .{ .contents = "appendonly YES\nappendonly yes", .err = Error.InvalidValue },
        .{ .contents = "save 0 1\nsave 60 1", .err = Error.InvalidValue },
        .{ .contents = "Port 7000", .err = Error.UnknownDirective },
        .{ .contents = "--port 7000", .err = Error.UnknownDirective },
        .{ .contents = "ready-fd 4", .err = Error.UnknownDirective },
        .{ .contents = "help yes", .err = Error.UnknownDirective },
        .{ .contents = "version yes", .err = Error.UnknownDirective },
        .{ .contents = "healthcheck yes", .err = Error.UnknownDirective },
    }) |case| {
        try testing.expectError(case.err, parse(testing.allocator, case.contents));
    }
}

test "parse discards accumulated states and token storage after file errors" {
    const testing = std.testing;
    for ([_]struct { contents: []const u8, err: Error }{
        .{ .contents = "save 60 1\nunknown value", .err = Error.UnknownDirective },
        .{ .contents = "save 60 1\nport", .err = Error.MalformedLine },
        .{ .contents = "save 60 1\nsave 300 10 extra", .err = Error.MalformedLine },
        .{ .contents = "save 60 1\nport invalid", .err = Error.InvalidValue },
        .{ .contents = "save 60 1\nsave 0 1", .err = Error.InvalidValue },
    }) |case| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{});
        try testing.expectError(case.err, parse(failing.allocator(), case.contents));
        try testing.expect(failing.allocated_bytes > 0);
        try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

test "parse cleans up every allocation failure in file application and finish" {
    const Run = struct {
        fn run(backing_allocator: std.mem.Allocator) !void {
            var failing_resize = std.testing.FailingAllocator.init(backing_allocator, .{ .resize_fail_index = 0 });
            const allocator = failing_resize.allocator();
            const contents = "port 7000\ndir data files\n" ++ ("save 60 1\n" ** 64);
            const config = try parse(allocator, contents);
            defer allocator.free(config.save_rules);
            try std.testing.expectEqual(7000, config.port);
            try std.testing.expectEqualStrings("data files", config.dir);
            try std.testing.expectEqual(64, config.save_rules.len);
            for (config.save_rules) |rule| {
                try std.testing.expectEqualDeep(Config.SaveRule{ .seconds = 60, .changes = 1 }, rule);
            }
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Run.run, .{});
}
