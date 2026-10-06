//! Definitions are static; mutable state belongs to each build.

const std = @import("std");
const Config = @import("../config.zig");

pub const Arity = @import("../arity.zig");

pub const CliValueCountFn = *const fn (remaining_values: []const []const u8) usize;

pub const InputRules = struct {
    pub const FileValues = enum {
        unsplit_value,
        tokens,
    };

    file_values: FileValues = .unsplit_value,
    /// Null consumes the minimum arity; variable counts supply a callback.
    cli_value_count: ?CliValueCountFn = null,
};

pub const RepeatPolicy = enum {
    replace,
    append,
};

pub const SaveOperation = union(enum) {
    rule: Config.SaveRule,
    /// Clear all rules collected so far in this layer.
    clear,
};

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

/// Callbacks must not retain the context.
pub const ApplyContext = struct {
    allocator: std.mem.Allocator,
    config: *Config,
    state: ?*anyopaque = null,
};

/// Validate contents without allocation or Config changes. Strings borrow input bytes.
pub const ParseFn = *const fn (values: []const []const u8) ParseError!Value;

pub const ApplyFn = *const fn (context: *ApplyContext, value: Value) ApplyError!void;

/// Reset only this directive's collection, without allocating.
pub const ResetFn = *const fn (context: *ApplyContext) void;

pub const CleanupMode = enum {
    /// Free temporary state and all output, including any already finalized slices.
    discard,
    /// Free temporary state, keeping data referenced by the returned Config.
    retain_config,
};

/// Errors must release partial allocations.
pub const StateInitFn = *const fn (allocator: std.mem.Allocator) ApplyError!*anyopaque;

/// State retains output until every finalizer succeeds.
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
    /// Choice bytes must have static storage.
    choices: ?[]const []const u8 = null,
    parse: ParseFn,
    apply: ApplyFn,
    reset: ?ResetFn = null,
    /// Mutable state is created separately for each build.
    state_lifecycle: ?StateLifecycle = null,
};

/// Borrows its definition and string bytes, but not the input slice array.
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
