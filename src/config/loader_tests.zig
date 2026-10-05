const std = @import("std");
const Config = @import("../config.zig");
const ConfigLoader = @import("loader.zig");
const registry = @import("registry.zig");
const directive_definition = @import("definition.zig");
const Cli = @import("../cli.zig");
const Manifest = @import("../persistence/manifest.zig");

test "load applies ordered scalar overrides without a file or allocation" {
    const testing = std.testing;
    const overrides = [_]directive_definition.PreparedDirective{
        try registry.prepare(registry.find("port").?, &.{"7000"}),
        try registry.prepare(registry.find("dir").?, &.{"data files"}),
        try registry.prepare(registry.find("port").?, &.{"7001"}),
    };
    const config = try ConfigLoader.load(testing.io, testing.failing_allocator, null, &overrides);
    var expected = Config.default();
    expected.port = 7001;
    expected.dir = "data files";
    try testing.expectEqualDeep(expected, config);
}

test "load keeps untouched file values and replaces save rules on the first CLI occurrence" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "kgcache.conf" });
    defer testing.allocator.free(path);
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "kgcache.conf",
        .data = "port 7000\ndir file data\nappendonly yes\nsave 60 1\nsave 900 100",
    });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const save = registry.find("save").?;
    const port = registry.find("port").?;
    const overrides = [_]directive_definition.PreparedDirective{
        try registry.prepare(port, &.{"7001"}),
        try registry.prepare(save, &.{ "300", "10" }),
        try registry.prepare(port, &.{"7002"}),
        try registry.prepare(save, &.{ "600", "20" }),
    };
    const config = try ConfigLoader.load(testing.io, arena.allocator(), path, &overrides);
    try testing.expectEqual(7002, config.port);
    try testing.expectEqualStrings("file data", config.dir);
    try testing.expect(config.append_only);
    try testing.expectEqualDeep(&[_]Config.SaveRule{
        .{ .seconds = 300, .changes = 10 },
        .{ .seconds = 600, .changes = 20 },
    }, config.save_rules);

    const scalar_only = try ConfigLoader.load(testing.io, arena.allocator(), path, overrides[0..1]);
    try testing.expectEqualDeep(&[_]Config.SaveRule{
        .{ .seconds = 60, .changes = 1 },
        .{ .seconds = 900, .changes = 100 },
    }, scalar_only.save_rules);
    const clear = [_]directive_definition.PreparedDirective{try registry.prepare(save, &.{""})};
    const cleared = try ConfigLoader.load(testing.io, arena.allocator(), path, &clear);
    try testing.expectEqual(0, cleared.save_rules.len);

    // Even overridden file values must pass validation.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "kgcache.conf", .data = "save 60 1\nport invalid" });
    try testing.expectError(error.InvalidValue, ConfigLoader.load(testing.io, testing.allocator, path, &overrides));
    try testing.expectError(error.FileNotFound, ConfigLoader.load(testing.io, testing.allocator, "scratch-missing-cli-config.conf", &clear));
}

test "persistence paths use the final file and CLI configuration" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "kgcache.conf" });
    defer testing.allocator.free(path);

    const path_arg = try testing.allocator.dupeZ(u8, path);
    defer testing.allocator.free(path_arg);

    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "kgcache.conf",
        .data = "dir file data\ndbfilename file.kgc\nappenddirname file-aof\nappendfilename file.aof",
    });

    const cases = [_]struct {
        args: []const [*:0]const u8,
        snapshot: []const u8,
        aof_directory: []const u8,
        aof_manifest: []const u8,
        aof_incremental: []const u8,
    }{
        .{
            .args = &.{},
            .snapshot = "file data/file.kgc",
            .aof_directory = "file data/file-aof",
            .aof_manifest = "file data/file-aof/file.aof.manifest",
            .aof_incremental = "file data/file-aof/file.aof.1.incr",
        },
        .{
            .args = &.{ "--dir", "cli data" },
            .snapshot = "cli data/file.kgc",
            .aof_directory = "cli data/file-aof",
            .aof_manifest = "cli data/file-aof/file.aof.manifest",
            .aof_incremental = "cli data/file-aof/file.aof.1.incr",
        },
        .{
            .args = &.{ "--dbfilename", "state.kgc" },
            .snapshot = "file data/state.kgc",
            .aof_directory = "file data/file-aof",
            .aof_manifest = "file data/file-aof/file.aof.manifest",
            .aof_incremental = "file data/file-aof/file.aof.1.incr",
        },
        .{
            .args = &.{ "--appenddirname", "history", "--appendfilename", "journal.aof" },
            .snapshot = "file data/file.kgc",
            .aof_directory = "file data/history",
            .aof_manifest = "file data/history/journal.aof.manifest",
            .aof_incremental = "file data/history/journal.aof.1.incr",
        },
        .{
            .args = &.{
                "--dir", "first data", "--dbfilename", "first.kgc", "--appenddirname", "first-aof", "--appendfilename", "first.aof",
                "--dir", "final data", "--dbfilename", "state.kgc", "--appenddirname", "history",   "--appendfilename", "journal.aof",
            },
            .snapshot = "final data/state.kgc",
            .aof_directory = "final data/history",
            .aof_manifest = "final data/history/journal.aof.manifest",
            .aof_incremental = "final data/history/journal.aof.1.incr",
        },
    };

    for (cases) |case| {
        var argv: [18][*:0]const u8 = undefined;
        argv[0] = "kgcache";
        argv[1] = path_arg.ptr;
        @memcpy(argv[2..][0..case.args.len], case.args);
        var cli = try Cli.parse(testing.allocator, .{ .vector = argv[0 .. 2 + case.args.len] });
        defer cli.deinit();

        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();

        const config = try ConfigLoader.load(testing.io, arena.allocator(), cli.config_path, cli.overrides.items);
        const snapshot = try config.resolveSnapshotPath(testing.allocator);
        defer testing.allocator.free(snapshot);

        try testing.expectEqualStrings(case.snapshot, snapshot);
        const aof_directory = try config.resolveAofDirectory(testing.allocator);
        defer testing.allocator.free(aof_directory);

        try testing.expectEqualStrings(case.aof_directory, aof_directory);
        const manifest_name = try Manifest.manifestName(testing.allocator, config.append_filename);
        defer testing.allocator.free(manifest_name);

        const manifest_path = try std.fs.path.join(testing.allocator, &.{ aof_directory, manifest_name });
        defer testing.allocator.free(manifest_path);

        try testing.expectEqualStrings(case.aof_manifest, manifest_path);
        const incremental_name = try Manifest.incrName(testing.allocator, config.append_filename, 1);
        defer testing.allocator.free(incremental_name);

        const incremental_path = try std.fs.path.join(testing.allocator, &.{ aof_directory, incremental_name });
        defer testing.allocator.free(incremental_path);

        try testing.expectEqualStrings(case.aof_incremental, incremental_path);
    }
}

test "load frees the file buffer and builder output after CLI apply or finalizer failure" {
    const Probe = struct {
        fn apply(_: *directive_definition.ApplyContext, _: directive_definition.Value) directive_definition.ApplyError!void {
            return error.OutOfMemory;
        }

        fn finalize(_: *directive_definition.ApplyContext) directive_definition.BuildError!void {
            return error.OutOfMemory;
        }
    };
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "kgcache.conf" });
    defer testing.allocator.free(path);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "kgcache.conf", .data = "dir file data\nsave 60 1" });

    var apply_failure = registry.find("port").?.*;
    apply_failure.apply = Probe.apply;
    var finalize_failure = registry.find("save").?.*;
    finalize_failure.state_lifecycle.?.finalize = Probe.finalize;
    for ([_]directive_definition.PreparedDirective{
        try registry.prepare(&apply_failure, &.{"7000"}),
        try registry.prepare(&finalize_failure, &.{ "300", "10" }),
    }) |prepared| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{});
        try testing.expectError(error.OutOfMemory, ConfigLoader.load(testing.io, failing.allocator(), path, &.{prepared}));
        try testing.expect(failing.allocated_bytes > 0);
        try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

test "load cleans up every allocation failure in CLI application and finalization" {
    const Run = struct {
        fn run(backing_allocator: std.mem.Allocator) !void {
            var failing_resize = std.testing.FailingAllocator.init(backing_allocator, .{ .resize_fail_index = 0 });
            const allocator = failing_resize.allocator();
            var overrides: [66]directive_definition.PreparedDirective = undefined;
            overrides[0] = try registry.prepare(registry.find("save").?, &.{""});
            for (overrides[1..65], 0..) |*prepared, index| {
                prepared.* = .{
                    .definition = registry.find("save").?,
                    .value = .{ .save = .{ .rule = .{ .seconds = @intCast(index + 1), .changes = 1 } } },
                };
            }
            overrides[65] = try registry.prepare(registry.find("port").?, &.{"7000"});
            const config = try ConfigLoader.load(std.testing.io, allocator, null, &overrides);
            defer allocator.free(config.save_rules);
            try std.testing.expectEqual(7000, config.port);
            try std.testing.expectEqual(64, config.save_rules.len);
            try std.testing.expectEqualDeep(Config.SaveRule{ .seconds = 1, .changes = 1 }, config.save_rules[0]);
            try std.testing.expectEqualDeep(Config.SaveRule{ .seconds = 64, .changes = 1 }, config.save_rules[63]);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Run.run, .{});
}
