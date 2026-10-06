const std = @import("std");
const definition = @import("definition.zig");
const registry = @import("registry.zig");

pub const PrepareError = definition.ParseError || std.mem.Allocator.Error;
pub const FileError = PrepareError || error{MalformedLine};

const SyntaxError = std.mem.Allocator.Error || error{MalformedLine};

pub fn prepareFile(
    arena: *std.heap.ArenaAllocator,
    directive: *const definition.Definition,
    text: []const u8,
) FileError!definition.PreparedDirective {
    var unsplit_value: [1][]const u8 = undefined;
    var token_values: std.ArrayList([]const u8) = .empty;
    defer token_values.deinit(arena.allocator());

    const values: []const []const u8 = switch (directive.input.file_values) {
        .unsplit_value => blk: {
            unsplit_value[0] = try decodeUnsplit(arena, text);
            break :blk &unsplit_value;
        },
        .tokens => blk: {
            try appendTokens(arena, text, &token_values);
            break :blk token_values.items;
        },
    };

    return registry.prepare(directive, values);
}

pub fn prepareArgs(
    arena: *std.heap.ArenaAllocator,
    directive: *const definition.Definition,
    args: []const []const u8,
) PrepareError!definition.PreparedDirective {
    var prepared = try registry.prepare(directive, args);

    // only string needs copy since it's size is variable. every thing else has fixed size
    switch (prepared.value) {
        .string => |bytes| prepared.value.string = try arena.allocator().dupe(u8, bytes),
        else => {},
    }

    return prepared;
}

fn decodeUnsplit(arena: *std.heap.ArenaAllocator, text: []const u8) SyntaxError![]const u8 {
    if (text.len == 0 or text[0] != '"') return text;

    const quoted = try scanQuoted(text);
    if (std.mem.trim(u8, text[quoted.end..], " \t").len != 0) return error.MalformedLine;

    return decodeQuoted(arena, text, quoted);
}

const QuotedSpan = struct {
    end: usize,
    decoded_len: usize,
};

fn scanQuoted(text: []const u8) error{MalformedLine}!QuotedSpan {
    std.debug.assert(text.len > 0 and text[0] == '"');

    var index: usize = 1;
    var decoded_len: usize = 0;
    while (index < text.len) : (index += 1) {
        switch (text[index]) {
            '"' => return .{ .end = index + 1, .decoded_len = decoded_len },
            '\\' => {
                index += 1;
                if (index == text.len or (text[index] != '"' and text[index] != '\\')) return error.MalformedLine;
            },
            '\n', '\r' => return error.MalformedLine,
            else => {},
        }
        decoded_len += 1;
    }
    return error.MalformedLine;
}

fn decodeQuoted(arena: *std.heap.ArenaAllocator, text: []const u8, quoted: QuotedSpan) std.mem.Allocator.Error![]const u8 {
    const contents = text[1 .. quoted.end - 1];
    if (contents.len == quoted.decoded_len) return contents;

    const decoded = try arena.allocator().alloc(u8, quoted.decoded_len);
    var index: usize = 0;
    for (decoded) |*byte| {
        if (contents[index] == '\\') index += 1;
        byte.* = contents[index];
        index += 1;
    }
    return decoded;
}

fn appendTokens(arena: *std.heap.ArenaAllocator, text: []const u8, values: *std.ArrayList([]const u8)) SyntaxError!void {
    var index: usize = 0;
    while (index < text.len) {
        while (index < text.len and (text[index] == ' ' or text[index] == '\t')) : (index += 1) {}
        if (index == text.len) break;

        const start = index;
        const token = if (text[start] == '"') blk: {
            const remaining = text[start..];
            const quoted = try scanQuoted(remaining);
            index += quoted.end;
            if (index < text.len and text[index] != ' ' and text[index] != '\t') return error.MalformedLine;
            break :blk try decodeQuoted(arena, remaining, quoted);
        } else blk: {
            while (index < text.len and text[index] != ' ' and text[index] != '\t') : (index += 1) {}
            break :blk text[start..index];
        };
        try values.append(arena.allocator(), token);
    }
}

test {
    std.testing.refAllDecls(@This());
    const file: *const fn (*std.heap.ArenaAllocator, *const definition.Definition, []const u8) FileError!definition.PreparedDirective = prepareFile;
    const args: *const fn (*std.heap.ArenaAllocator, *const definition.Definition, []const []const u8) PrepareError!definition.PreparedDirective = prepareArgs;
    _ = file;
    _ = args;
}

test "decodeUnsplit preserves unquoted bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    for ([_][]const u8{ "", " \t ", "data files", " a\"b\\c '#literal'\t " }) |text| {
        const decoded = try decodeUnsplit(&arena, text);
        try std.testing.expectEqualStrings(text, decoded);
    }
}

test "decodeUnsplit removes boundary quotes and preserves inner bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const cases = [_]struct { text: []const u8, expected: []const u8 }{
        .{ .text = "\"\"", .expected = "" },
        .{ .text = "\"data files\"", .expected = "data files" },
        .{ .text = "\" data\tfiles \" \t", .expected = " data\tfiles " },
        .{ .text = "\"'single' #literal\"", .expected = "'single' #literal" },
        .{ .text = "\"a\\\"b\\\\c\"", .expected = "a\"b\\c" },
        .{ .text = "\"\\\"data files\\\"\"", .expected = "\"data files\"" },
        .{ .text = "\"\\\\\\\"\"", .expected = "\\\"" },
    };
    for (cases) |case| {
        try std.testing.expectEqualStrings(case.expected, try decodeUnsplit(&arena, case.text));
    }
}

test "decodeUnsplit rejects incomplete quotes, invalid escapes, and trailing text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    for ([_][]const u8{
        "\"",
        "\"unterminated",
        "\"escaped close\\\"",
        "\"trailing\\",
        "\"bad\\q\"",
        "\"bad\\n\"",
        "\"bad\\t\"",
        "\"data\"extra",
        "\"data\" extra",
        "\"data\"\"files\"",
        "\"data\" \t#comment",
        "\"data\nfiles\"",
        "\"data\rfiles\"",
        "\"data\" \n",
        "\"data\" \r",
    }) |text| {
        try std.testing.expectError(error.MalformedLine, decodeUnsplit(&arena, text));
    }
}

test "appendTokens produces no values for empty input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var values: std.ArrayList([]const u8) = .empty;
    defer values.deinit(arena.allocator());

    for ([_][]const u8{ "", " \t\t " }) |text| {
        try appendTokens(&arena, text, &values);
        try std.testing.expectEqual(0, values.items.len);
    }
}

test "appendTokens preserves mixed token bytes and quoted whitespace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cases = [_]struct { text: []const u8, expected: []const []const u8 }{
        .{
            .text = " \t\"alpha beta\"\tplain \" a\tb \" \"\" a\"b c\\d 'single' #literal ",
            .expected = &.{ "alpha beta", "plain", " a\tb ", "", "a\"b", "c\\d", "'single'", "#literal" },
        },
        .{ .text = "\"a\\\"b\\\\c\"", .expected = &.{"a\"b\\c"} },
        .{ .text = "\"\" \"one two\" \"\"", .expected = &.{ "", "one two", "" } },
        .{ .text = "'two words'", .expected = &.{ "'two", "words'" } },
        .{ .text = "last \"final\"", .expected = &.{ "last", "final" } },
    };
    for (cases) |case| {
        var values: std.ArrayList([]const u8) = .empty;
        defer values.deinit(arena.allocator());
        try appendTokens(&arena, case.text, &values);
        try std.testing.expectEqual(case.expected.len, values.items.len);
        for (case.expected, values.items) |expected, actual| {
            try std.testing.expectEqualStrings(expected, actual);
        }
    }
}

test "appendTokens rejects malformed quotes and missing token separators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{
        "\"",
        "plain \"unterminated",
        "\"escaped close\\\"",
        "\"trailing\\",
        "\"bad\\q\"",
        "\"bad\\n\"",
        "\"data\"extra",
        "\"data\"\"files\"",
        "\"data\"\\next",
        "\"data\nfiles\"",
        "\"data\rfiles\"",
        "\"data\"\n",
        "\"data\"\r",
    }) |text| {
        var values: std.ArrayList([]const u8) = .empty;
        defer values.deinit(arena.allocator());
        try std.testing.expectError(error.MalformedLine, appendTokens(&arena, text, &values));
    }
}

test "appendTokens preserves unquoted bytes and releases storage on allocation failures" {
    const Run = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var failing_resize = std.testing.FailingAllocator.init(allocator, .{ .resize_fail_index = 0 });
            var arena = std.heap.ArenaAllocator.init(failing_resize.allocator());
            defer arena.deinit();
            var values: std.ArrayList([]const u8) = .empty;
            defer values.deinit(arena.allocator());

            const expected = [_][]const u8{
                "alpha", "beta\"gamma", "path\\name", "'single'", "#literal",
                "one",   "two",         "three",      "four",     "five",
                "six",   "seven",       "eight",      "nine",     "ten",
                "last",
            };
            try appendTokens(
                &arena,
                "alpha \t beta\"gamma path\\name 'single' #literal one two three four five six seven eight nine ten last",
                &values,
            );
            try std.testing.expectEqual(expected.len, values.items.len);

            for (expected, values.items) |wanted, actual| try std.testing.expectEqualStrings(wanted, actual);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Run.run, .{});
}
