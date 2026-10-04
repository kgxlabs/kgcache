const std = @import("std");
const Cli = @import("cli.zig");
const Config = @import("config.zig");
const ConfigLoader = @import("config/loader.zig");
const registry = @import("config/registry.zig");

test "CLI prepares every directive in argv order beside process arguments" {
    const testing = std.testing;
    var cli = try Cli.parse(testing.allocator, .{ .vector = &.{
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

    const config = try ConfigLoader.load(testing.io, testing.allocator, null, cli.overrides.items);
    defer testing.allocator.free(config.save_rules);
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

test "CLI deinit releases owned storage while Config keeps borrowing argv bytes" {
    const testing = std.testing;
    const directory = try testing.allocator.dupeZ(u8, "data files");
    defer testing.allocator.free(directory);
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const config = blk: {
        var cli = try Cli.parse(failing.allocator(), .{ .vector = &.{ "kgcache", "--dir", directory.ptr } });
        defer cli.deinit();
        try testing.expect(failing.allocated_bytes > failing.freed_bytes);
        try testing.expect(cli.overrides.items[0].value.string.ptr == directory.ptr);
        break :blk try ConfigLoader.load(testing.io, testing.failing_allocator, null, cli.overrides.items);
    };
    try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    try testing.expect(config.dir.ptr == directory.ptr);
    directory[0] = 'D';
    try testing.expectEqualStrings("Data files", config.dir);
}

test "CLI cleans up every allocation failure in argument storage and prepared list growth" {
    const Run = struct {
        fn run(backing_allocator: std.mem.Allocator) !void {
            var failing_resize = std.testing.FailingAllocator.init(backing_allocator, .{ .resize_fail_index = 0 });
            var argv: [1 + 64 * 3][*:0]const u8 = undefined;
            argv[0] = "kgcache";
            for (0..64) |index| {
                const start = 1 + index * 3;
                argv[start..][0..3].* = .{ "--save", "60", "1" };
            }
            var cli = try Cli.parse(failing_resize.allocator(), .{ .vector = &argv });
            defer cli.deinit();
            try std.testing.expectEqual(64, cli.overrides.items.len);
            for (cli.overrides.items) |prepared| {
                try std.testing.expectEqualDeep(
                    Config.SaveRule{ .seconds = 60, .changes = 1 },
                    prepared.value.save.rule,
                );
            }
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Run.run, .{});
}
