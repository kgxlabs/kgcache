const std = @import("std");
const Config = @import("../config.zig");

pub const Arity = @import("../arity.zig");

/// Selects a variable CLI value count from the remaining arguments.
/// The CLI parser checks that the selected count is available before preparation.
pub const CliValueCountFn = *const fn (remaining_values: []const []const u8) usize;

/// Source syntax rules used before the registry validates values.
pub const InputRules = struct {
    pub const FileValues = enum {
        unsplit_value,
        tokens,
    };

    file_values: FileValues = .unsplit_value,
    cli_value_count: ?CliValueCountFn = null,
    /// When enabled, the exact file remainder `""` becomes one empty value.
    normalize_empty_file_value: bool = false,
};

pub const RepeatPolicy = enum {
    replace,
    append,
};

pub const SaveOperation = union(enum) {
    rule: Config.SaveRule,
    /// Reserved for the later save clearing support.
    clear,
};

/// Parsed values are copied, except strings, which borrow their source input.
pub const Value = union(enum) {
    u16_value: u16,
    u32_value: u32,
    usize_value: usize,
    i8_value: i8,
    i64_value: i64,
    boolean: bool,
    string: []const u8,
    append_fsync: Config.AppendFsync,
    save: SaveOperation,
};

/// Metadata for one supported config directive.
pub const Definition = struct {
    name: []const u8,
    arity: Arity,
    input: InputRules = .{},
    repeat: RepeatPolicy = .replace,
    /// Static, case-sensitive spellings for a directive with exact arity one.
    /// Null leaves value validation to the parser; a list must be nonempty and unique.
    choices: ?[]const []const u8 = null,
};

/// A static definition and its parsed value, ready for later application.
pub const PreparedDirective = struct {
    definition: *const Definition,
    value: Value,
};

test {
    std.testing.refAllDecls(@This());
}
