const std = @import("std");
const Config = @import("../config.zig");
const ConfigBuilder = @import("builder.zig");
const ConfigParser = @import("../config_parser.zig");
const PreparedDirective = @import("definition.zig").PreparedDirective;

/// Build defaults, apply an optional file, then apply prepared CLI values in order.
/// Borrows the override slice only during construction and never frees it. String
/// bytes borrowed from argv must remain alive while the returned Config is used.
/// Use an arena that outlives Config: on success, the file buffer is retained for
/// borrowed strings and is not returned separately. The arena also owns save_rules.
/// On failure, frees builder data and the file buffer.
pub fn load(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: ?[]const u8,
    overrides: []const PreparedDirective,
) anyerror!Config {
    var contents: ?[]u8 = null;
    errdefer if (contents) |bytes| allocator.free(bytes);
    var builder = ConfigBuilder.init(allocator);
    defer builder.deinit();

    if (path) |config_path| {
        contents = try std.Io.Dir.cwd().readFileAlloc(io, config_path, allocator, .unlimited);
        try ConfigParser.apply(&builder, contents.?);
    }
    for (overrides) |prepared| try builder.apply(prepared, .cli);
    return builder.finish();
}

/// Compatibility wrapper for file-only loading. Null path returns defaults
/// without allocation. Ownership and cleanup match load.
pub fn loadFromPath(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: ?[]const u8,
) anyerror!Config {
    return load(io, allocator, path, &.{});
}

test {
    std.testing.refAllDecls(@This());
}

test "loadFromPath returns defaults without allocating when no path is supplied" {
    const testing = std.testing;
    const config = try loadFromPath(testing.io, testing.failing_allocator, null);
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
    const config = try loadFromPath(testing.io, arena.allocator(), path);

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
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "kgcache.conf" });
    defer testing.allocator.free(path);

    try testing.expectError(error.FileNotFound, loadFromPath(testing.io, testing.allocator, path));

    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "kgcache.conf",
        .data = "save 60 1\nport invalid",
    });
    try testing.expectError(error.OutOfMemory, loadFromPath(testing.io, testing.failing_allocator, path));
    try testing.expectError(error.InvalidValue, loadFromPath(testing.io, testing.allocator, path));
}
