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
    _ = arena;
    if (text.len > 0 and text[0] == '"') @panic("quoted file values are not implemented");

    return text;
}

fn appendTokens(arena: *std.heap.ArenaAllocator, text: []const u8, values: *std.ArrayList([]const u8)) SyntaxError!void {
    var tokens = std.mem.tokenizeAny(u8, text, " \t");
    while (tokens.next()) |token| {
        if (token[0] == '"') @panic("quoted file values are not implemented");
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
