//! Apply file syntax through registry preparation and builder application.
//! Blank lines and full-line comments are skipped. Quotes and inline # stay literal
//! except for empty values explicitly normalized by a definition's InputRules.

const std = @import("std");
const Config = @import("config.zig");
const ConfigBuilder = @import("config/builder.zig");
const registry = @import("config/registry.zig");
const directive_definition = @import("config/definition.zig");

pub const Error = error{
    /// A line is missing a directive or value, or has an invalid value count.
    MalformedLine,
    /// The first token on a line isn't a supported directive name.
    UnknownDirective,
    /// The value couldn't be parsed or is outside the directive's valid range.
    InvalidValue,
    /// Allocating parsing or builder storage failed.
    OutOfMemory,
};

/// Start a builder, apply this file, finish once, and always clean up temporary state.
/// Returned strings borrow contents, which must remain alive while Config is used.
/// The caller owns allocated save_rules: free with allocator or release its arena.
/// On failure, builder-owned output and temporary token storage are freed.
pub fn parse(allocator: std.mem.Allocator, contents: []const u8) Error!Config {
    var builder = ConfigBuilder.init(allocator);
    defer builder.deinit();

    try apply(&builder, contents);
    return builder.finish();
}

/// Apply to an existing builder; the caller finishes once and always calls deinit.
/// Keep contents alive for borrowed Config strings; temporary tokens are freed on exit.
/// Invalid arity maps to MalformedLine. Any file error ends the build.
pub fn apply(builder: *ConfigBuilder, contents: []const u8) Error!void {
    std.debug.assert(builder.status == .building);
    errdefer builder.status = .failed;

    // Reuse the slice array across token-based lines. Values borrow contents,
    // not this array; preparation copies save numbers before the array is cleared.
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
        // accept "" as empty value
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
