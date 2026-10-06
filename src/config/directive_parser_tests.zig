const std = @import("std");
const testing = std.testing;
const parser = @import("directive_parser.zig");
const registry = @import("registry.zig");
const definition = @import("definition.zig");

test "prepareArgs retains literal string bytes after input changes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const original = " \"data\\files\" \t";
    var source = original.*;
    var args = [_][]const u8{&source};
    const directive = registry.find("dir").?;
    const prepared = try parser.prepareArgs(&arena, directive, &args);

    @memset(&source, 'x');
    args[0] = "replacement";
    try testing.expect(prepared.definition == directive);
    try testing.expectEqualStrings(original, prepared.value.string);
}

test "prepareArgs copies non-string values without allocating or retaining arguments" {
    var arena = std.heap.ArenaAllocator.init(testing.failing_allocator);
    defer arena.deinit();

    const cases = [_]struct { name: []const u8, args: []const []const u8, expected: definition.Value }{
        .{ .name = "port", .args = &.{"7000"}, .expected = .{ .u16_value = 7000 } },
        .{ .name = "auto-aof-rewrite-percentage", .args = &.{"100"}, .expected = .{ .u32_value = 100 } },
        .{ .name = "connection-buffer-size", .args = &.{"2048"}, .expected = .{ .usize_value = 2048 } },
        .{ .name = "active-expire-budget-ms", .args = &.{"10"}, .expected = .{ .i8_value = 10 } },
        .{ .name = "cron-interval-ms", .args = &.{"100"}, .expected = .{ .i64_value = 100 } },
        .{ .name = "appendonly", .args = &.{"yes"}, .expected = .{ .boolean = true } },
        .{ .name = "appendfsync", .args = &.{"no"}, .expected = .{ .append_fsync = .no } },
        .{ .name = "save", .args = &.{ "60", "1" }, .expected = .{ .save = .{ .rule = .{ .seconds = 60, .changes = 1 } } } },
        .{ .name = "save", .args = &.{""}, .expected = .{ .save = .clear } },
    };
    for (cases) |case| {
        var args: [2][]const u8 = undefined;
        @memcpy(args[0..case.args.len], case.args);
        const prepared = try parser.prepareArgs(&arena, registry.find(case.name).?, args[0..case.args.len]);
        args = .{ "changed", "changed" };
        try testing.expectEqualDeep(case.expected, prepared.value);
    }
}

test "prepareArgs validates before allocating retained strings" {
    var arena = std.heap.ArenaAllocator.init(testing.failing_allocator);
    defer arena.deinit();

    try testing.expectError(error.InvalidArity, parser.prepareArgs(&arena, registry.find("dir").?, &.{}));
    try testing.expectError(error.InvalidArity, parser.prepareArgs(&arena, registry.find("dir").?, &.{ "data", "files" }));
    try testing.expectError(error.InvalidValue, parser.prepareArgs(&arena, registry.find("dir").?, &.{"data\x00files"}));
    try testing.expectError(error.InvalidValue, parser.prepareArgs(&arena, registry.find("port").?, &.{"\"7000\""}));
    try testing.expectError(error.InvalidValue, parser.prepareArgs(&arena, registry.find("appendonly").?, &.{"\"yes\""}));
    try testing.expectError(error.InvalidValue, parser.prepareArgs(&arena, registry.find("appendfsync").?, &.{"\"no\""}));
    try testing.expectError(error.OutOfMemory, parser.prepareArgs(&arena, registry.find("dir").?, &.{"data files"}));
}

test "prepareArgs arena cleanup covers every allocation failure" {
    const Run = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var failing_resize = testing.FailingAllocator.init(allocator, .{ .resize_fail_index = 0 });
            var arena = std.heap.ArenaAllocator.init(failing_resize.allocator());
            defer arena.deinit();

            const directive = registry.find("dir").?;
            const first = try parser.prepareArgs(&arena, directive, &.{"data files"});
            var source: [4096]u8 = undefined;
            @memset(&source, 'x');
            const second = try parser.prepareArgs(&arena, directive, &.{&source});
            @memset(&source, 'y');

            try testing.expectEqualStrings("data files", first.value.string);
            try testing.expectEqual(4096, second.value.string.len);
            for (second.value.string) |byte| try testing.expectEqual(@as(u8, 'x'), byte);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Run.run, .{});
}
