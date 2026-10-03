const std = @import("std");
const Config = @import("../config.zig");

pub const Arity = @import("../arity.zig");

/// The CLI parser checks that the returned count fits the remaining arguments.
pub const CliValueCountFn = *const fn (remaining_values: []const []const u8) usize;

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
    clear,
};

/// Strings borrow the source input.
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

pub const ParseError = error{
    InvalidArity,
    InvalidValue,
};

pub const ApplyError = std.mem.Allocator.Error;

pub const BuildError = std.mem.Allocator.Error;

pub const ApplyContext = struct {
    allocator: std.mem.Allocator,
    config: *Config,
    state: ?*anyopaque = null,
};

pub const ParseFn = *const fn (values: []const []const u8) ParseError!Value;

pub const ApplyFn = *const fn (context: *ApplyContext, value: Value) ApplyError!void;

/// Clears this directive's accumulated values without allocating.
pub const ResetFn = *const fn (context: *ApplyContext) void;

pub const CleanupMode = enum {
    /// Free temporary state and any finalized output.
    discard,
    /// Free temporary state, keeping data referenced by the returned Config.
    retain_config,
};

/// Releases partial allocations on failure.
pub const StateInitFn = *const fn (allocator: std.mem.Allocator) ApplyError!*anyopaque;

/// State owns finalized output until builder finish succeeds.
pub const StateFinalizeFn = *const fn (context: *ApplyContext) BuildError!void;

pub const StateDeinitFn = *const fn (context: *ApplyContext, mode: CleanupMode) void;

pub const StateLifecycle = struct {
    init: StateInitFn,
    finalize: StateFinalizeFn,
    deinit: StateDeinitFn,
};

pub const Definition = struct {
    name: []const u8,
    arity: Arity,
    input: InputRules = .{},
    repeat: RepeatPolicy = .replace,
    /// Static, case-sensitive choices for exact arity one; nonempty and unique.
    choices: ?[]const []const u8 = null,
    parse: ParseFn,
    apply: ApplyFn,
    reset: ?ResetFn = null,
    /// Mutable state is created separately for each build.
    state_lifecycle: ?StateLifecycle = null,
};

pub const PreparedDirective = struct {
    definition: *const Definition,
    value: Value,
};

test {
    std.testing.refAllDecls(@This());
    _ = @sizeOf(Definition);
    _ = @sizeOf(ApplyContext);
    _ = @sizeOf(StateLifecycle);
}
