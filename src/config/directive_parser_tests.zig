const std = @import("std");
const testing = std.testing;
const parser = @import("directive_parser.zig");
const registry = @import("registry.zig");
const definition = @import("definition.zig");

test "prepareFile preserves unquoted string bytes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const source = "data \tfiles a\"b\\c '#literal'";
    const prepared = try parser.prepareFile(&arena, registry.find("dir").?, source);

    try testing.expectEqualStrings(source, prepared.value.string);
}

test "prepareFile prepares unquoted scalars and rejects invalid values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try testing.expectEqualDeep(definition.Value{ .u16_value = 7000 }, (try parser.prepareFile(&arena, registry.find("port").?, "7000")).value);
    try testing.expectEqualDeep(definition.Value{ .boolean = true }, (try parser.prepareFile(&arena, registry.find("appendonly").?, "yes")).value);
    try testing.expectEqualDeep(definition.Value{ .append_fsync = .everysec }, (try parser.prepareFile(&arena, registry.find("appendfsync").?, "everysec")).value);
    try testing.expectError(error.InvalidValue, parser.prepareFile(&arena, registry.find("port").?, "invalid"));
    try testing.expectError(error.InvalidValue, parser.prepareFile(&arena, registry.find("dir").?, ""));
}

test "prepareFile splits unquoted save values on spaces and tabs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const directive = registry.find("save").?;

    for ([_][]const u8{ "60 1", "60 \t\t 1", " \t60\t1\t " }) |text| {
        const prepared = try parser.prepareFile(&arena, directive, text);
        try testing.expect(prepared.definition == directive);
        try testing.expectEqualDeep(definition.Value{ .save = .{ .rule = .{ .seconds = 60, .changes = 1 } } }, prepared.value);
    }
    for ([_][]const u8{ "", "60", "60 1 2" }) |text| {
        try testing.expectError(error.InvalidArity, parser.prepareFile(&arena, directive, text));
    }
    for ([_][]const u8{ "invalid 1", "60 0", "'60' 1" }) |text| {
        try testing.expectError(error.InvalidValue, parser.prepareFile(&arena, directive, text));
    }
}

test "prepareFile token allocation failures clean up through the caller arena" {
    const Run = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const prepared = try parser.prepareFile(&arena, registry.find("save").?, "60\t1");
            try testing.expectEqualDeep(definition.Value{ .save = .{ .rule = .{ .seconds = 60, .changes = 1 } } }, prepared.value);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Run.run, .{});
}

test "prepareArgs retains literal strings after input changes and later preparation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const original = " \"data\\files\" \t";
    var source = original.*;
    var args = [_][]const u8{&source};
    const directive = registry.find("dir").?;
    const prepared = try parser.prepareArgs(&arena, directive, &args);

    @memset(&source, 'x');
    args[0] = "replacement";

    const save = registry.find("save").?;
    _ = try parser.prepareFile(&arena, save, "60\t1");
    try testing.expectError(error.InvalidValue, parser.prepareFile(&arena, save, "60 0"));
    const later = try parser.prepareArgs(&arena, directive, &.{"later files"});

    try testing.expect(prepared.definition == directive);
    try testing.expectEqualStrings(original, prepared.value.string);
    try testing.expectEqualStrings("later files", later.value.string);
}

test "prepareArgs prepares scalar and save values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
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
        const prepared = try parser.prepareArgs(&arena, registry.find(case.name).?, case.args);
        try testing.expectEqualDeep(case.expected, prepared.value);
    }
}

test "prepareArgs rejects invalid arity and literal invalid values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.InvalidArity, parser.prepareArgs(&arena, registry.find("dir").?, &.{}));
    try testing.expectError(error.InvalidArity, parser.prepareArgs(&arena, registry.find("dir").?, &.{ "data", "files" }));
    try testing.expectError(error.InvalidValue, parser.prepareArgs(&arena, registry.find("dir").?, &.{"data\x00files"}));
    try testing.expectError(error.InvalidValue, parser.prepareArgs(&arena, registry.find("port").?, &.{"\"7000\""}));
    try testing.expectError(error.InvalidValue, parser.prepareArgs(&arena, registry.find("appendonly").?, &.{"\"yes\""}));
    try testing.expectError(error.InvalidValue, parser.prepareArgs(&arena, registry.find("appendfsync").?, &.{"\"no\""}));
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
