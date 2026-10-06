const std = @import("std");
const Cli = @import("cli.zig");
const Config = @import("config.zig");
const ConfigLoader = @import("config/loader.zig");
const registry = @import("config/registry.zig");

test "CLI consumes required values by position without changing option parsing" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][*:0]const u8{ "-data", "--", "--ready-fd", "healthcheck", "--dir=value" }) |value| {
        var cli = try Cli.parse(&arena, .{ .vector = &.{ "kgcache", "--dir", value, "--port", "7000" } });
        defer cli.deinit();
        try testing.expect(cli.config_path == null);
        try testing.expect(cli.ready_fd == null);
        const config = try ConfigLoader.load(testing.io, &arena, null, cli.overrides.items);
        try testing.expectEqualStrings(std.mem.span(value), config.dir);
        try testing.expectEqual(7000, config.port);
    }
}

test "CLI rejects a bare double hyphen at an argument boundary" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const invocations = [_][]const [*:0]const u8{
        &.{ "kgcache", "--" },
        &.{ "kgcache", "--", "-cache.conf" },
        &.{ "kgcache", "cache.conf", "--", "other.conf" },
        &.{ "kgcache", "--port", "7000", "--", "cache.conf" },
        &.{ "kgcache", "--dir", "--", "--", "cache.conf" },
        &.{ "kgcache", "--ready-fd", "3", "--", "--ready-fd" },
        &.{ "kgcache", "--", "healthcheck" },
    };
    for (invocations) |argv| {
        try testing.expectError(error.UnknownFlag, Cli.parse(&arena, .{ .vector = argv }));
    }
}

test "config path placement preserves file before CLI precedence" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "-cache.conf" });
    defer testing.allocator.free(path);
    const path_arg = try testing.allocator.dupeZ(u8, path);
    defer testing.allocator.free(path_arg);
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "-cache.conf",
        .data = "port 7000\nbind 0.0.0.0\ndatabases 4\nsave 900 1",
    });
    const invocations = [_][]const [*:0]const u8{
        &.{ "kgcache", path_arg.ptr, "--port", "8000", "--bind", "127.0.0.1" },
        &.{ "kgcache", "--port", "8000", path_arg.ptr, "--bind", "127.0.0.1" },
        &.{ "kgcache", "--port", "8000", "--bind", "127.0.0.1", path_arg.ptr },
    };
    for (invocations) |argv| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var cli = try Cli.parse(&arena, .{ .vector = argv });
        defer cli.deinit();
        try testing.expectEqualStrings(path, cli.config_path.?);
        const config = try ConfigLoader.load(testing.io, &arena, cli.config_path, cli.overrides.items);
        var expected = Config.default();
        expected.port = 8000;
        expected.num_databases = 4;
        expected.save_rules = &.{.{ .seconds = 900, .changes = 1 }};
        try testing.expectEqualDeep(expected, config);
    }
}

test "CLI leaves a trailing positional token after a complete save option" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][*:0]const u8{ "cache.conf", "2" }) |path| {
        var cli = try Cli.parse(&arena, .{ .vector = &.{ "kgcache", "--save", "60", "1", path } });
        defer cli.deinit();
        try testing.expectEqualStrings(std.mem.span(path), cli.config_path.?);
        try testing.expectEqual(1, cli.overrides.items.len);
        try testing.expectEqualDeep(Config.SaveRule{ .seconds = 60, .changes = 1 }, cli.overrides.items[0].value.save.rule);
    }
}

test "CLI save rules replace file rules and apply clears in input order" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "kgcache.conf" });
    defer testing.allocator.free(path);
    const path_arg = try testing.allocator.dupeZ(u8, path);
    defer testing.allocator.free(path_arg);
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "kgcache.conf",
        .data = "port 7000\ndir file data\nappendonly yes\nsave 900 1\nsave 300 10",
    });
    const file_rules = &[_]Config.SaveRule{
        .{ .seconds = 900, .changes = 1 },
        .{ .seconds = 300, .changes = 10 },
    };
    const first_rule = &[_]Config.SaveRule{.{ .seconds = 60, .changes = 1 }};
    const two_rules = &[_]Config.SaveRule{
        .{ .seconds = 60, .changes = 1 },
        .{ .seconds = 300, .changes = 10 },
    };
    const cases = [_]struct { args: []const [*:0]const u8, rules: []const Config.SaveRule }{
        .{ .args = &.{}, .rules = &.{} },
        .{ .args = &.{ "--save", "60", "1" }, .rules = first_rule },
        .{ .args = &.{ "--save", "" }, .rules = &.{} },
        .{ .args = &.{ "--save", "", "--save", "60", "1" }, .rules = first_rule },
        .{ .args = &.{ "--save", "60", "1", "--save", "" }, .rules = &.{} },
        .{ .args = &.{ "--save", "60", "1", "--save", "300", "10" }, .rules = two_rules },
        .{ .args = &.{ "--save", "", "--save", "" }, .rules = &.{} },
        .{ .args = &.{ "--save", "60", "1", "--save", "", "--save", "" }, .rules = &.{} },
        .{ .args = &.{ "--save", "", "--save", "60", "1", "--save", "" }, .rules = &.{} },
        .{ .args = &.{ "--save", "", "--save", "", "--save", "60", "1", "--save", "300", "10" }, .rules = two_rules },
        .{ .args = &.{ "--save", "900", "100", "--save", "", "--save", "", "--save", "60", "1", "--save", "300", "10" }, .rules = two_rules },
    };
    for ([_]bool{ false, true }) |with_file| {
        for (cases) |case| {
            var argv: [17][*:0]const u8 = undefined;
            argv[0] = "kgcache";
            const start: usize = if (with_file) 2 else 1;
            if (with_file) argv[1] = path_arg.ptr;
            @memcpy(argv[start..][0..case.args.len], case.args);
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            var cli = try Cli.parse(&arena, .{ .vector = argv[0 .. start + case.args.len] });
            defer cli.deinit();
            const config = try ConfigLoader.load(testing.io, &arena, cli.config_path, cli.overrides.items);
            var expected = Config.default();
            if (with_file) {
                expected.port = 7000;
                expected.dir = "file data";
                expected.append_only = true;
            }
            expected.save_rules = if (with_file and case.args.len == 0) file_rules else case.rules;
            try testing.expectEqualDeep(expected, config);
        }
    }
}

test "CLI rejects invalid save rules after valid rules and clears" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const prefixes = [_][]const [*:0]const u8{
        &.{},
        &.{ "--save", "60", "1" },
        &.{ "--save", "" },
        &.{ "--save", "60", "1", "--save", "" },
    };
    const invalid_rules = [_]struct { args: []const [*:0]const u8, err: Cli.Error }{
        .{ .args = &.{ "--save", "0", "1" }, .err = error.InvalidValue },
        .{ .args = &.{ "--save", "60", "0" }, .err = error.InvalidValue },
        .{ .args = &.{ "--save", "invalid", "1" }, .err = error.InvalidValue },
        .{ .args = &.{ "--save", "60", "invalid" }, .err = error.InvalidValue },
        .{ .args = &.{ "--save", "\"\"", "1" }, .err = error.InvalidValue },
        .{ .args = &.{"--save"}, .err = error.MissingValue },
        .{ .args = &.{ "--save", "60" }, .err = error.MissingValue },
    };
    for (prefixes) |prefix| {
        for (invalid_rules) |case| {
            var argv: [10][*:0]const u8 = undefined;
            argv[0] = "kgcache";
            argv[1] = "scratch-missing-cli-config.conf";
            @memcpy(argv[2..][0..prefix.len], prefix);
            @memcpy(argv[2 + prefix.len ..][0..case.args.len], case.args);
            try testing.expectError(case.err, Cli.parse(&arena, .{ .vector = argv[0 .. 2 + prefix.len + case.args.len] }));
        }
    }
}

test "CLI prepares every directive in argv order beside process arguments" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cli = try Cli.parse(&arena, .{ .vector = &.{
        "kgcache",                 "--bind",                            "0.0.0.0",                   "--port",                     "7000",
        "--reuse-address",         "no",                                "--connection-buffer-size",  "2048",                       "--databases",
        "4",                       "--dir",                             "data files",                "--dbfilename",               "state.kgc",
        "--cron-interval-ms",      "250",                               "--active-expire-budget-ms", "15",                         "--active-expire-batch-size",
        "30",                      "--active-expire-threshold-percent", "50",                        "--exclusive-bg-persistence", "no",
        "--save",                  "60",                                "1",                         "--ready-fd",                 "3",
        "cache.conf",              "--appendonly",                      "yes",                       "--appendfsync",              "always",
        "--appenddirname",         "history",                           "--appendfilename",          "journal.aof",                "--auto-aof-rewrite-percentage",
        "0",                       "--auto-aof-rewrite-min-size",       "2048",                      "--aof-load-truncated",       "no",
        "--bgsave-retry-delay-ms", "0",                                 "--port",                    "7001",                       "--save",
        "",                        "--save",                            "300",                       "10",
    } });
    defer cli.deinit();
    try testing.expectEqualStrings("cache.conf", cli.config_path.?);
    try testing.expectEqual(3, cli.ready_fd.?);
    try testing.expectEqual(registry.all().len + 3, cli.overrides.items.len);
    for (registry.all(), cli.overrides.items[0..registry.all().len]) |definition, prepared| {
        try testing.expectEqualStrings(definition.name, prepared.definition.name);
    }

    const config = try ConfigLoader.load(testing.io, &arena, null, cli.overrides.items);
    var expected = Config.default();
    expected.bind_address = "0.0.0.0";
    expected.port = 7001;
    expected.reuse_address = false;
    expected.connection_buffer_size = 2048;
    expected.num_databases = 4;
    expected.dir = "data files";
    expected.dbfilename = "state.kgc";
    expected.cron_interval_ms = 250;
    expected.active_expire_budget_ms = 15;
    expected.active_expire_batch_size = 30;
    expected.active_expire_threshold_percent = 50;
    expected.exclusive_bg_persistence = false;
    expected.save_rules = &.{.{ .seconds = 300, .changes = 10 }};
    expected.append_only = true;
    expected.append_fsync = .always;
    expected.append_dirname = "history";
    expected.append_filename = "journal.aof";
    expected.auto_aof_rewrite_percentage = 0;
    expected.auto_aof_rewrite_min_size = 2048;
    expected.aof_load_truncated = false;
    expected.bgsave_retry_delay_ms = 0;
    try testing.expectEqualDeep(expected, config);
}

test "CLI preserves literal values and config path after argv is released" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const original_path = "config \"files\"\\cache.conf";
    const original_directory = "\"data\\files\"\t";

    var cli = blk: {
        const path = try testing.allocator.dupeZ(u8, original_path);
        defer testing.allocator.free(path);
        const directory = try testing.allocator.dupeZ(u8, original_directory);
        defer testing.allocator.free(directory);
        const parsed = try Cli.parse(&arena, .{ .vector = &.{ "kgcache", path.ptr, "--dir", directory.ptr, "--port", "7000" } });
        @memset(path, 'x');
        @memset(directory, 'y');
        break :blk parsed;
    };
    defer cli.deinit();

    try testing.expectEqualStrings(original_path, cli.config_path.?);
    const config = try ConfigLoader.load(testing.io, &arena, null, cli.overrides.items);
    try testing.expectEqualStrings(original_directory, config.dir);
    try testing.expectEqual(7000, config.port);
}

test "CLI cleanup leaves loaded Config usable after argv is released" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const config = blk: {
        const directory = try testing.allocator.dupeZ(u8, "data files");
        defer testing.allocator.free(directory);
        var cli = try Cli.parse(&arena, .{ .vector = &.{ "kgcache", "--dir", directory.ptr } });
        defer cli.deinit();
        break :blk try ConfigLoader.load(testing.io, &arena, null, cli.overrides.items);
    };
    try testing.expectEqualStrings("data files", config.dir);
}

test "CLI caller cleanup covers allocation failures with retained values and config path" {
    const Run = struct {
        fn run(backing_allocator: std.mem.Allocator) !void {
            var failing_resize = std.testing.FailingAllocator.init(backing_allocator, .{ .resize_fail_index = 0 });
            const directory = "x" ** 4096;
            var argv: [4 + 64 * 3][*:0]const u8 = undefined;
            argv[0..3].* = .{ "kgcache", "--dir", directory };
            for (0..64) |index| {
                const start = 3 + index * 3;
                argv[start..][0..3].* = .{ "--save", "60", "1" };
            }
            argv[3 + 64 * 3] = "config files.conf";
            var arena = std.heap.ArenaAllocator.init(failing_resize.allocator());
            defer arena.deinit();
            var cli = try Cli.parse(&arena, .{ .vector = &argv });
            defer cli.deinit();
            try std.testing.expectEqualStrings("config files.conf", cli.config_path.?);
            const config = try ConfigLoader.load(std.testing.io, &arena, null, cli.overrides.items);
            try std.testing.expectEqualStrings(directory, config.dir);
            try std.testing.expectEqual(64, config.save_rules.len);
            for (config.save_rules) |rule| {
                try std.testing.expectEqualDeep(
                    Config.SaveRule{ .seconds = 60, .changes = 1 },
                    rule,
                );
            }
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Run.run, .{});
}
