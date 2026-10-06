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

test "prepareFile decodes quoted scalars before registry validation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const cases = [_]struct { name: []const u8, text: []const u8, expected: definition.Value }{
        .{ .name = "port", .text = "\"7000\"", .expected = .{ .u16_value = 7000 } },
        .{ .name = "connection-buffer-size", .text = "\"2048\"", .expected = .{ .usize_value = 2048 } },
        .{ .name = "appendonly", .text = "\"yes\"", .expected = .{ .boolean = true } },
        .{ .name = "appendfsync", .text = "\"everysec\"", .expected = .{ .append_fsync = .everysec } },
        .{ .name = "dir", .text = "\" data\tfiles \" \t", .expected = .{ .string = " data\tfiles " } },
        .{ .name = "dbfilename", .text = "\"state file.kgc\"", .expected = .{ .string = "state file.kgc" } },
    };
    for (cases) |case| {
        const prepared = try parser.prepareFile(&arena, registry.find(case.name).?, case.text);
        try testing.expectEqualDeep(case.expected, prepared.value);
    }
}

test "prepareFile distinguishes malformed scalar quotes from invalid decoded values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const cases = [_]struct { name: []const u8, text: []const u8, err: parser.FileError }{
        .{ .name = "port", .text = "\"invalid\"", .err = error.InvalidValue },
        .{ .name = "port", .text = "\"invalid\" extra", .err = error.MalformedLine },
        .{ .name = "port", .text = "\"\"", .err = error.InvalidValue },
        .{ .name = "port", .text = "\" 7000 \"", .err = error.InvalidValue },
        .{ .name = "dir", .text = "\"\"", .err = error.InvalidValue },
        .{ .name = "dir", .text = "\"data\\q\"", .err = error.MalformedLine },
        .{ .name = "appendonly", .text = "\"YES\"", .err = error.InvalidValue },
        .{ .name = "appendfsync", .text = "\"Always\"", .err = error.InvalidValue },
        .{ .name = "dbfilename", .text = "\"data/state.kgc\"", .err = error.InvalidValue },
    };
    for (cases) |case| {
        try testing.expectError(case.err, parser.prepareFile(&arena, registry.find(case.name).?, case.text));
    }
}

test "prepareFile escaped strings survive source release and later preparation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const directive = registry.find("dir").?;
    const prepared = blk: {
        const source = try testing.allocator.dupe(u8, "\"a\\\"b\\\\c\"");
        defer testing.allocator.free(source);
        const result = try parser.prepareFile(&arena, directive, source);
        @memset(source, 'x');
        break :blk result;
    };
    const later = try parser.prepareFile(&arena, directive, "\"later\\\\files\"");
    _ = try parser.prepareFile(&arena, registry.find("save").?, "60 1");
    try testing.expectError(error.MalformedLine, parser.prepareFile(&arena, directive, "\"invalid\" extra"));

    try testing.expectEqualStrings("a\"b\\c", prepared.value.string);
    try testing.expectEqualStrings("later\\files", later.value.string);
}

test "prepareFile caller cleanup covers escaped scalar allocation failures" {
    const Run = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const directive = registry.find("dir").?;
            const first = try parser.prepareFile(&arena, directive, "\"a\\\"b\\\\c\"");
            const second = try parser.prepareFile(&arena, directive, "\"" ++ ("a\\\\b" ** 2048) ++ "\"");

            try testing.expectEqualStrings("a\"b\\c", first.value.string);
            try testing.expectEqualStrings("a\\b" ** 2048, second.value.string);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Run.run, .{});
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

test "prepareFile validates mixed quoted save tokens and empty tokens" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const directive = registry.find("save").?;
    for ([_][]const u8{ "\"60\" \"1\"", "\"60\" 1", "60 \"1\"", " \t\"60\"\t\"1\"\t " }) |text| {
        const prepared = try parser.prepareFile(&arena, directive, text);
        try testing.expectEqualDeep(definition.Value{ .save = .{ .rule = .{ .seconds = 60, .changes = 1 } } }, prepared.value);
    }
    for ([_][]const u8{ "\"\"", " \t\"\"\t " }) |text| {
        const prepared = try parser.prepareFile(&arena, directive, text);
        try testing.expectEqualDeep(definition.Value{ .save = .clear }, prepared.value);
    }
    const rejected = [_]struct { text: []const u8, err: parser.FileError }{
        .{ .text = "\"60 1\"", .err = error.InvalidArity },
        .{ .text = "\" \"", .err = error.InvalidArity },
        .{ .text = "\"\t\"", .err = error.InvalidArity },
        .{ .text = "\"60\"", .err = error.InvalidArity },
        .{ .text = "\"\" \"60\" \"1\"", .err = error.InvalidArity },
        .{ .text = "\" 60 \" \"1\"", .err = error.InvalidValue },
        .{ .text = "\"60\" \" 1 \"", .err = error.InvalidValue },
        .{ .text = "\"0\" \"1\"", .err = error.InvalidValue },
        .{ .text = "\"60\" \"0\"", .err = error.InvalidValue },
        .{ .text = "\"\" \"1\"", .err = error.InvalidValue },
        .{ .text = "\"\" \"\"", .err = error.InvalidValue },
        .{ .text = "\"6\\\"0\" \"1\"", .err = error.InvalidValue },
        .{ .text = "\"60\" \"1\\\\0\"", .err = error.InvalidValue },
        .{ .text = "\"60\"1", .err = error.MalformedLine },
        .{ .text = "\"60\"\"1\"", .err = error.MalformedLine },
        .{ .text = "\"60\" \"1\"extra", .err = error.MalformedLine },
        .{ .text = "\"60\\q\" \"1\"", .err = error.MalformedLine },
        .{ .text = "\"60\" \"unterminated", .err = error.MalformedLine },
    };
    for (rejected) |case| {
        try testing.expectError(case.err, parser.prepareFile(&arena, directive, case.text));
    }
}

test "prepareFile retains escaped token strings after temporary cleanup" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var directive = registry.find("dir").?.*;
    directive.input.file_values = .tokens;
    const prepared = blk: {
        const source = try testing.allocator.dupe(u8, "\"a\\\"b\\\\c\"");
        defer testing.allocator.free(source);
        const result = try parser.prepareFile(&arena, &directive, source);
        @memset(source, 'x');
        break :blk result;
    };
    const later = try parser.prepareFile(&arena, &directive, "\"later\\\\files\"");
    _ = try parser.prepareFile(&arena, registry.find("save").?, "\"60\" \"1\"");
    try testing.expectEqualStrings("a\"b\\c", prepared.value.string);
    try testing.expectEqualStrings("later\\files", later.value.string);
}

test "prepareFile caller cleanup covers escaped token allocation failures" {
    const Run = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            var directive = registry.find("dir").?.*;
            directive.input.file_values = .tokens;
            const first = try parser.prepareFile(&arena, &directive, "\"a\\\"b\\\\c\"");
            const second = try parser.prepareFile(&arena, &directive, "\"" ++ ("a\\\\b" ** 2048) ++ "\"");
            try testing.expectEqualStrings("a\"b\\c", first.value.string);
            try testing.expectEqualStrings("a\\b" ** 2048, second.value.string);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Run.run, .{});
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
    const directive = registry.find("dir").?;
    const prepared = blk: {
        const source = try testing.allocator.dupe(u8, original);
        defer testing.allocator.free(source);
        var args = [_][]const u8{source};
        const result = try parser.prepareArgs(&arena, directive, &args);
        @memset(source, 'x');
        args[0] = "replacement";
        break :blk result;
    };

    const save = registry.find("save").?;
    _ = try parser.prepareFile(&arena, save, "60\t1");
    try testing.expectError(error.InvalidValue, parser.prepareFile(&arena, save, "60 0"));
    try testing.expectError(error.InvalidValue, parser.prepareArgs(&arena, directive, &.{"bad\x00value"}));
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
