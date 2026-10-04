//! Definitions are static; mutable state belongs to each build.

const std = @import("std");
const Config = @import("../config.zig");

pub const Arity = @import("../arity.zig");

/// Reserved for future CLI value counting; current definitions leave it null.
pub const CliValueCountFn = *const fn (remaining_values: []const []const u8) usize;

pub const InputRules = struct {
    pub const FileValues = enum {
        /// The trimmed remainder is one value, preserving spaces and literal quotes.
        unsplit_value,
        tokens,
    };

    file_values: FileValues = .unsplit_value,
    cli_value_count: ?CliValueCountFn = null,
    /// Reserved for future file `""` normalization; disabled in current definitions.
    normalize_empty_file_value: bool = false,
};

pub const RepeatPolicy = enum {
    replace,
    append,
};

pub const SaveOperation = union(enum) {
    rule: Config.SaveRule,
    /// Reserved; the current save parser accepts only rules.
    clear,
};

/// Numbers, booleans, enums, and save rules are copied. Strings borrow source bytes,
/// which must remain alive while the prepared value or resulting Config is used.
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

/// Borrows the working Config and per-build state (null for stateless definitions).
/// Callbacks must not retain the context itself.
pub const ApplyContext = struct {
    allocator: std.mem.Allocator,
    config: *Config,
    state: ?*anyopaque = null,
};

/// Validate contents without allocation or Config changes. Strings borrow input bytes.
pub const ParseFn = *const fn (values: []const []const u8) ParseError!Value;

/// Apply a prepared value to the working Config or this definition's state.
pub const ApplyFn = *const fn (context: *ApplyContext, value: Value) ApplyError!void;

/// Clear only this definition's collection before finalization, without allocating.
/// This does not restore Config defaults. Current file loading never invokes reset.
pub const ResetFn = *const fn (context: *ApplyContext) void;

pub const CleanupMode = enum {
    /// Free temporary state and all output, including any already finalized slices.
    discard,
    /// Free temporary state, keeping data referenced by the returned Config.
    retain_config,
};

/// Create one state per used definition per build, reused by later occurrences.
/// On failure, release partial allocations before returning the error.
pub const StateInitFn = *const fn (allocator: std.mem.Allocator) ApplyError!*anyopaque;

/// Assign completed data to the working Config. State still owns that output until
/// every finalizer succeeds; a later failure must allow discard to free it.
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
    /// Optional scalar choices: exact arity one, nonempty list, unique spellings.
    /// Membership is case-sensitive; the list and its strings have static storage.
    /// Null skips membership checking; the parser's other constraints still apply.
    /// Boolean and enum helpers derive choices from their conversion spellings.
    /// Future help output and documentation checks may also read these choices.
    choices: ?[]const []const u8 = null,
    parse: ParseFn,
    apply: ApplyFn,
    reset: ?ResetFn = null,
    /// Mutable state is created separately for each build.
    state_lifecycle: ?StateLifecycle = null,
};

/// A validated value ready for builder application. Does not borrow the temporary
/// array of input slices; its definition and any string bytes must remain alive.
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
