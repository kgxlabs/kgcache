const std = @import("std");
const Config = @import("../config.zig");
const ConfigBuilder = @import("builder.zig");
const ConfigParser = @import("../config_parser.zig");
const PreparedDirective = @import("definition.zig").PreparedDirective;

/// Caller keeps the arena and borrowed override bytes alive through Config use.
pub fn load(
    io: std.Io,
    arena: *std.heap.ArenaAllocator,
    path: ?[]const u8,
    overrides: []const PreparedDirective,
) anyerror!Config {
    const allocator = arena.allocator();
    var contents: ?[]u8 = null;
    errdefer if (contents) |bytes| allocator.free(bytes);

    var builder = ConfigBuilder.init(allocator);
    defer builder.deinit();

    if (path) |config_path| {
        contents = try std.Io.Dir.cwd().readFileAlloc(io, config_path, allocator, .unlimited);
        try ConfigParser.apply(&builder, arena, contents.?);
    }

    for (overrides) |prepared| try builder.apply(prepared, .cli);

    return builder.finish();
}

pub fn loadFromPath(
    io: std.Io,
    arena: *std.heap.ArenaAllocator,
    path: ?[]const u8,
) anyerror!Config {
    return load(io, arena, path, &.{});
}

test {
    std.testing.refAllDecls(@This());
}

test "loadFromPath returns defaults when no path is supplied" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const config = try loadFromPath(testing.io, &arena, null);
    try testing.expectEqualDeep(Config.default(), config);
}

test "loadFromPath reads file values and collects save rules" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "kgcache.conf" });
    defer testing.allocator.free(path);

    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "kgcache.conf",
        .data =
        \\port 7000
        \\dir data files
        \\save 60 1
        \\save 300 10
        ,
    });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const config = try loadFromPath(testing.io, &arena, path);

    var expected = Config.default();
    expected.port = 7000;
    expected.dir = "data files";
    expected.save_rules = &.{
        .{ .seconds = 60, .changes = 1 },
        .{ .seconds = 300, .changes = 10 },
    };
    try testing.expectEqualDeep(expected, config);
}

test "loadFromPath preserves source errors and cleans up failed parsing" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "kgcache.conf" });
    defer testing.allocator.free(path);

    try testing.expectError(error.FileNotFound, loadFromPath(testing.io, &arena, path));

    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "kgcache.conf",
        .data = "save 60 1\nport invalid",
    });
    var failing_arena = std.heap.ArenaAllocator.init(testing.failing_allocator);
    defer failing_arena.deinit();
    try testing.expectError(error.OutOfMemory, loadFromPath(testing.io, &failing_arena, path));
    try testing.expectError(error.InvalidValue, loadFromPath(testing.io, &arena, path));
}
