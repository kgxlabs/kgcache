const std = @import("std");
const Config = @import("config.zig");
const ConfigBuilder = @import("config/builder.zig");
const registry = @import("config/registry.zig");
const directive_definition = @import("config/definition.zig");

pub const Error = error{
    MalformedLine,
    UnknownDirective,
    InvalidValue,
    OutOfMemory,
};

pub fn parse(allocator: std.mem.Allocator, contents: []const u8) Error!Config {
    var builder = ConfigBuilder.init(allocator);
    defer builder.deinit();

    try apply(&builder, contents);
    return builder.finish();
}

pub fn apply(builder: *ConfigBuilder, contents: []const u8) Error!void {
    std.debug.assert(builder.status == .building);
    errdefer builder.status = .failed;

    var token_values: std.ArrayList([]const u8) = .empty;
    defer token_values.deinit(builder.allocator);

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        const space = std.mem.indexOfAny(u8, line, " \t") orelse return Error.MalformedLine;
        const directive_name = line[0..space];
        const value = std.mem.trim(u8, line[space..], " \t");
        if (value.len == 0) return Error.MalformedLine;

        const definition = registry.find(directive_name) orelse return Error.UnknownDirective;
        const normalize_empty = definition.input.normalize_empty_file_value and std.mem.eql(u8, value, "\"\"");
        var normalized_value = value;
        if (normalize_empty) {
            normalized_value = "";
        }

        const unsplit_value = [_][]const u8{normalized_value};
        const values: []const []const u8 = if (normalize_empty) &unsplit_value else switch (definition.input.file_values) {
            .unsplit_value => &unsplit_value,
            .tokens => blk: {
                token_values.clearRetainingCapacity();

                var tokens = std.mem.tokenizeAny(u8, value, " \t");
                while (tokens.next()) |token| try token_values.append(builder.allocator, token);
                break :blk token_values.items;
            },
        };

        const prepared = registry.prepare(
            definition,
            values,
        ) catch |err| return mapParseError(err);
        try builder.apply(prepared, .file);
    }
}

fn mapParseError(err: directive_definition.ParseError) Error {
    return switch (err) {
        error.InvalidArity => Error.MalformedLine,
        error.InvalidValue => Error.InvalidValue,
    };
}

test {
    std.testing.refAllDecls(@This());
}
