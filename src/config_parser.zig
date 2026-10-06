const std = @import("std");
const Config = @import("config.zig");
const ConfigBuilder = @import("config/builder.zig");
const ConfigDirectiveParser = @import("config/directive_parser.zig");
const registry = @import("config/registry.zig");

pub const Error = error{
    MalformedLine,
    UnknownDirective,
    InvalidValue,
    OutOfMemory,
};

pub fn parse(arena: *std.heap.ArenaAllocator, contents: []const u8) Error!Config {
    var builder = ConfigBuilder.init(arena.allocator());
    defer builder.deinit();

    try apply(&builder, arena, contents);
    return builder.finish();
}

pub fn apply(builder: *ConfigBuilder, arena: *std.heap.ArenaAllocator, contents: []const u8) Error!void {
    std.debug.assert(builder.status == .building);
    errdefer builder.status = .failed;

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        const space = std.mem.indexOfAny(u8, line, " \t") orelse return Error.MalformedLine;
        const directive_name = line[0..space];
        const value = std.mem.trim(u8, line[space..], " \t");
        if (value.len == 0) return Error.MalformedLine;

        const definition = registry.find(directive_name) orelse return Error.UnknownDirective;
        const prepared = ConfigDirectiveParser.prepareFile(arena, definition, value) catch |err| return mapPreparationError(err);

        try builder.apply(prepared, .file);
    }
}

fn mapPreparationError(err: ConfigDirectiveParser.FileError) Error {
    return switch (err) {
        error.InvalidArity, error.MalformedLine => Error.MalformedLine,
        error.InvalidValue => Error.InvalidValue,
        error.OutOfMemory => Error.OutOfMemory,
    };
}

test {
    std.testing.refAllDecls(@This());
}
