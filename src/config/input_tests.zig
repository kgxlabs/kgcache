const std = @import("std");
const Config = @import("../config.zig");
const ConfigParser = @import("../config_parser.zig");
const ConfigLoader = @import("loader.zig");
const Cli = @import("../cli.zig");

fn expectEquivalentInput(
    name: []const u8,
    file_value: []const u8,
    cli_values: []const [:0]const u8,
    expected: anyerror!Config,
) !void {
    const testing = std.testing;
    const contents = try std.fmt.allocPrint(testing.allocator, " \t{s}\t {s} \r\n", .{ name, file_value });
    defer testing.allocator.free(contents);
    const flag = try std.fmt.allocPrint(testing.allocator, "--{s}", .{name});
    defer testing.allocator.free(flag);
    const flag_arg = try testing.allocator.dupeZ(u8, flag);
    defer testing.allocator.free(flag_arg);
    const argv = try testing.allocator.alloc([*:0]const u8, 2 + cli_values.len);
    defer testing.allocator.free(argv);
    argv[0] = "kgcache";
    argv[1] = flag_arg.ptr;
    for (cli_values, argv[2..]) |value, *arg| arg.* = value.ptr;

    if (expected) |wanted| {
        const file_config = try ConfigParser.parse(testing.allocator, contents);
        defer testing.allocator.free(file_config.save_rules);
        try testing.expectEqualDeep(wanted, file_config);
        var cli = try Cli.parse(testing.allocator, .{ .vector = argv });
        defer cli.deinit();
        const cli_config = try ConfigLoader.load(testing.io, testing.allocator, null, cli.overrides.items);
        defer testing.allocator.free(cli_config.save_rules);
        try testing.expectEqualDeep(wanted, cli_config);
    } else |err| {
        try testing.expectError(err, ConfigParser.parse(testing.allocator, contents));
        try testing.expectError(err, Cli.parse(testing.allocator, .{ .vector = argv }));
    }
}

test "file and CLI numeric settings accept the same boundaries and reject invalid values" {
    const testing = std.testing;
    const cases = .{
        .{ .name = "port", .field = "port", .minimum = @as(i128, 0), .maximum = std.math.maxInt(u16) },
        .{ .name = "connection-buffer-size", .field = "connection_buffer_size", .minimum = @as(i128, 1), .maximum = std.math.maxInt(usize) },
        .{ .name = "databases", .field = "num_databases", .minimum = @as(i128, 1), .maximum = @min(std.math.maxInt(u32), std.math.maxInt(usize)) },
        .{ .name = "cron-interval-ms", .field = "cron_interval_ms", .minimum = @as(i128, 1), .maximum = std.math.maxInt(i64) },
        .{ .name = "active-expire-budget-ms", .field = "active_expire_budget_ms", .minimum = @as(i128, 1), .maximum = std.math.maxInt(i8) },
        .{ .name = "active-expire-batch-size", .field = "active_expire_batch_size", .minimum = @as(i128, 1), .maximum = std.math.maxInt(i8) },
        .{ .name = "active-expire-threshold-percent", .field = "active_expire_threshold_percent", .minimum = @as(i128, 1), .maximum = 100 },
        .{ .name = "auto-aof-rewrite-percentage", .field = "auto_aof_rewrite_percentage", .minimum = @as(i128, 0), .maximum = std.math.maxInt(u32) },
        .{ .name = "auto-aof-rewrite-min-size", .field = "auto_aof_rewrite_min_size", .minimum = @as(i128, 0), .maximum = std.math.maxInt(usize) },
        .{ .name = "bgsave-retry-delay-ms", .field = "bgsave_retry_delay_ms", .minimum = @as(i128, 0), .maximum = std.math.maxInt(i64) },
    };
    inline for (cases) |case| {
        for ([_]i128{ case.minimum, case.maximum, case.minimum - 1, @as(i128, case.maximum) + 1 }) |number| {
            const text = try std.fmt.allocPrint(testing.allocator, "{d}", .{number});
            defer testing.allocator.free(text);
            const value = try testing.allocator.dupeZ(u8, text);
            defer testing.allocator.free(value);
            if (number < case.minimum or number > case.maximum) {
                try expectEquivalentInput(case.name, text, &.{value}, error.InvalidValue);
            } else {
                var expected = Config.default();
                @field(expected, case.field) = @intCast(number);
                try expectEquivalentInput(case.name, text, &.{value}, expected);
            }
        }
        for ([_][:0]const u8{ "invalid", "1.5", "\"1\"", "1kb", "0x10", "--1" }) |value| {
            try expectEquivalentInput(case.name, value, &.{value}, error.InvalidValue);
        }
    }
}

test "file and CLI save rules accept the same numeric boundaries" {
    const accepted = [_]struct { text: []const u8, values: []const [:0]const u8, rule: Config.SaveRule }{
        .{ .text = "1 1", .values = &.{ "1", "1" }, .rule = .{ .seconds = 1, .changes = 1 } },
        .{ .text = "9223372036854775807 4294967295", .values = &.{ "9223372036854775807", "4294967295" }, .rule = .{ .seconds = std.math.maxInt(i64), .changes = std.math.maxInt(u32) } },
    };
    for (accepted) |case| {
        var expected = Config.default();
        expected.save_rules = &.{case.rule};
        try expectEquivalentInput("save", case.text, case.values, expected);
    }
    const rejected = [_]struct { text: []const u8, values: []const [:0]const u8 }{
        .{ .text = "0 1", .values = &.{ "0", "1" } },
        .{ .text = "-1 1", .values = &.{ "-1", "1" } },
        .{ .text = "9223372036854775808 1", .values = &.{ "9223372036854775808", "1" } },
        .{ .text = "1 0", .values = &.{ "1", "0" } },
        .{ .text = "1 -1", .values = &.{ "1", "-1" } },
        .{ .text = "1 4294967296", .values = &.{ "1", "4294967296" } },
    };
    for (rejected) |case| try expectEquivalentInput("save", case.text, case.values, error.InvalidValue);
    try expectEquivalentInput("save", "\"\"", &.{""}, Config.default());
}

test "file and CLI boolean and enum settings accept the same choices" {
    inline for (.{
        .{ .name = "reuse-address", .field = "reuse_address" },
        .{ .name = "exclusive-bg-persistence", .field = "exclusive_bg_persistence" },
        .{ .name = "appendonly", .field = "append_only" },
        .{ .name = "aof-load-truncated", .field = "aof_load_truncated" },
    }) |case| {
        for ([_][:0]const u8{ "yes", "no" }) |value| {
            var expected = Config.default();
            @field(expected, case.field) = std.mem.eql(u8, value, "yes");
            try expectEquivalentInput(case.name, value, &.{value}, expected);
        }
        for ([_][:0]const u8{ "YES", "No", "true", "false", "1", "0", "\"yes\"", "yes no" }) |value| {
            try expectEquivalentInput(case.name, value, &.{value}, error.InvalidValue);
        }
    }
    for ([_]Config.AppendFsync{ .always, .everysec, .no }) |choice| {
        const value = @tagName(choice);
        var expected = Config.default();
        expected.append_fsync = choice;
        try expectEquivalentInput("appendfsync", value, &.{value}, expected);
    }
    for ([_][:0]const u8{ "Always", "EVERYSEC", "yes", "invalid", "\"no\"", "no always" }) |value| {
        try expectEquivalentInput("appendfsync", value, &.{value}, error.InvalidValue);
    }
}

test "file and CLI persistence settings enforce the same path rules" {
    inline for (.{
        .{ .name = "dir", .field = "dir", .values = [_][:0]const u8{ "data files", "./data", "../data", "/absolute/path/to/data" } },
        .{ .name = "dbfilename", .field = "dbfilename", .values = [_][:0]const u8{ "state.kgc", "state file.kgc" } },
        .{ .name = "appenddirname", .field = "append_dirname", .values = [_][:0]const u8{ "history", "history files" } },
        .{ .name = "appendfilename", .field = "append_filename", .values = [_][:0]const u8{ "journal.aof", "history/journal.aof", "journal file.aof" } },
    }) |case| {
        for (case.values) |value| {
            var expected = Config.default();
            @field(expected, case.field) = value;
            try expectEquivalentInput(case.name, value, &.{value}, expected);
        }
    }
    for ([_][:0]const u8{ "state.rdb", "/absolute/path/state.kgc", "data/state.kgc", "../state.kgc", "data\\state.kgc" }) |value| {
        try expectEquivalentInput("dbfilename", value, &.{value}, error.InvalidValue);
    }
    for ([_][:0]const u8{ ".", "..", "/absolute/path/aof", "data/aof", "../aof", "data\\aof" }) |value| {
        try expectEquivalentInput("appenddirname", value, &.{value}, error.InvalidValue);
    }
}

test "file quotes remain literal while CLI receives shell grouped values" {
    const testing = std.testing;
    const file_config = try ConfigParser.parse(testing.allocator, "dir \"data files\"");
    defer testing.allocator.free(file_config.save_rules);
    try testing.expectEqualStrings("\"data files\"", file_config.dir);
    var cli = try Cli.parse(testing.allocator, .{ .vector = &.{ "kgcache", "--dir", "data files", "--port", "7000", "--appendonly", "yes", "--appendfsync", "always" } });
    defer cli.deinit();
    const cli_config = try ConfigLoader.load(testing.io, testing.allocator, null, cli.overrides.items);
    defer testing.allocator.free(cli_config.save_rules);
    var expected = Config.default();
    expected.dir = "data files";
    expected.port = 7000;
    expected.append_only = true;
    expected.append_fsync = .always;
    try testing.expectEqualDeep(expected, cli_config);
    for ([_][]const u8{ "port \"7000\"", "appendonly \"yes\"", "appendfsync \"always\"" }) |contents| {
        try testing.expectError(error.InvalidValue, ConfigParser.parse(testing.allocator, contents));
    }
    for ([_][*:0]const u8{ "dir", "dbfilename", "appenddirname", "appendfilename" }) |name| {
        const contents = try std.fmt.allocPrint(testing.allocator, "{s} \t\r\n", .{name});
        defer testing.allocator.free(contents);
        try testing.expectError(error.MalformedLine, ConfigParser.parse(testing.allocator, contents));
        const flag = try std.fmt.allocPrint(testing.allocator, "--{s}", .{name});
        defer testing.allocator.free(flag);
        const flag_arg = try testing.allocator.dupeZ(u8, flag);
        defer testing.allocator.free(flag_arg);
        try testing.expectError(error.InvalidValue, Cli.parse(testing.allocator, .{ .vector = &.{ "kgcache", flag_arg.ptr, "" } }));
    }
}
