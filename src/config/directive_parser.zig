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
    _ = arena;
    _ = directive;
    _ = text;
    @panic("prepareFile is not implemented");
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
    _ = text;
    @panic("decodeUnsplit is not implemented");
}

fn appendTokens(arena: *std.heap.ArenaAllocator, text: []const u8, values: *std.ArrayList([]const u8)) SyntaxError!void {
    _ = arena;
    _ = text;
    _ = values;
    @panic("appendTokens is not implemented");
}

test {
    std.testing.refAllDecls(@This());
    const file: *const fn (*std.heap.ArenaAllocator, *const definition.Definition, []const u8) FileError!definition.PreparedDirective = prepareFile;
    const args: *const fn (*std.heap.ArenaAllocator, *const definition.Definition, []const []const u8) PrepareError!definition.PreparedDirective = prepareArgs;
    const decode: *const fn (*std.heap.ArenaAllocator, []const u8) SyntaxError![]const u8 = decodeUnsplit;
    const append: *const fn (*std.heap.ArenaAllocator, []const u8, *std.ArrayList([]const u8)) SyntaxError!void = appendTokens;
    _ = file;
    _ = args;
    _ = decode;
    _ = append;
}
