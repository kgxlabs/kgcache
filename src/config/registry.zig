//! Prepare values from static definitions; the builder applies them and owns state.

const std = @import("std");
const Config = @import("../config.zig");
const directive_definition = @import("definition.zig");
const DirectiveDefinition = directive_definition.Definition;
const Arity = directive_definition.Arity;
const Value = directive_definition.Value;
const ValueTag = std.meta.Tag(Value);
const ParseError = directive_definition.ParseError;
const StringValidator = *const fn (value: []const u8) error{InvalidValue}!void;
const boolean_choices = [_][]const u8{ "yes", "no" };

/// Owns growing and finalized rules until the whole build succeeds.
const SaveState = struct {
    rules: std.ArrayList(Config.SaveRule) = .empty,
    finalized_rules: ?[]Config.SaveRule = null,
};

const definitions = [_]DirectiveDefinition{
    stringDirective("bind", "bind_address", null),
    integerDirective("port", "port", u16, 0, std.math.maxInt(u16)),
    booleanDirective("reuse-address", "reuse_address"),
    integerDirective("connection-buffer-size", "connection_buffer_size", usize, 1, std.math.maxInt(usize)),
    integerDirective("databases", "num_databases", usize, 1, @min(std.math.maxInt(u32), std.math.maxInt(usize))),
    stringDirective("dir", "dir", Config.validateDir),
    stringDirective("dbfilename", "dbfilename", Config.validateDbfilename),
    integerDirective("cron-interval-ms", "cron_interval_ms", i64, 1, std.math.maxInt(i64)),
    integerDirective("active-expire-budget-ms", "active_expire_budget_ms", i8, 1, std.math.maxInt(i8)),
    integerDirective("active-expire-batch-size", "active_expire_batch_size", i8, 1, std.math.maxInt(i8)),
    integerDirective("active-expire-threshold-percent", "active_expire_threshold_percent", i8, 1, 100),
    booleanDirective("exclusive-bg-persistence", "exclusive_bg_persistence"),
    saveDirective(),
    booleanDirective("appendonly", "append_only"),
    enumDirective("appendfsync", "append_fsync", Config.AppendFsync),
    stringDirective("appenddirname", "append_dirname", Config.validateAppendDirname),
    stringDirective("appendfilename", "append_filename", null),
    integerDirective("auto-aof-rewrite-percentage", "auto_aof_rewrite_percentage", u32, 0, std.math.maxInt(u32)),
    integerDirective("auto-aof-rewrite-min-size", "auto_aof_rewrite_min_size", usize, 0, std.math.maxInt(usize)),
    booleanDirective("aof-load-truncated", "aof_load_truncated"),
    integerDirective("bgsave-retry-delay-ms", "bgsave_retry_delay_ms", i64, 0, std.math.maxInt(i64)),
};

comptime {
    validateDefinitions(&definitions);
}

pub fn find(name: []const u8) ?*const DirectiveDefinition {
    for (&definitions) |*definition| {
        if (std.mem.eql(u8, name, definition.name)) return definition;
    }
    return null;
}

pub fn all() []const DirectiveDefinition {
    return &definitions;
}

pub fn prepare(
    definition: *const DirectiveDefinition,
    values: []const []const u8,
) directive_definition.ParseError!directive_definition.PreparedDirective {
    if (!definition.arity.accepts(values.len)) return error.InvalidArity;

    if (definition.choices) |choices| {
        std.debug.assert(values.len == 1);

        var matches_choice = false;

        for (choices) |choice| {
            if (std.mem.eql(u8, values[0], choice)) {
                matches_choice = true;
                break;
            }
        }

        if (!matches_choice) return error.InvalidValue;
    }

    return .{
        .definition = definition,
        .value = try definition.parse(values),
    };
}

fn validateDefinitions(comptime entries: []const DirectiveDefinition) void {
    @setEvalBranchQuota(10000);
    inline for (entries, 0..) |definition, index| {
        validateName(definition);
        validateArityAndInput(definition);
        validateRepeat(definition);
        validateChoices(definition);

        inline for (entries[index + 1 ..]) |other| {
            if (std.mem.eql(u8, definition.name, other.name)) {
                invalidDefinition(definition.name, "duplicates directive `" ++ other.name ++ "`");
            }
        }
    }
}

fn validateName(comptime definition: DirectiveDefinition) void {
    if (definition.name.len == 0) invalidDefinition(definition.name, "has an empty name");

    if (std.mem.startsWith(u8, definition.name, "--")) {
        invalidDefinition(definition.name, "name must not include the CLI `--` prefix");
    }

    inline for (definition.name) |byte| {
        const valid = std.ascii.isLower(byte) or std.ascii.isDigit(byte) or
            byte == '_' or byte == '-' or byte == '.';

        if (!valid) invalidDefinition(definition.name, "name must use lowercase ASCII letters, digits, `_`, `-`, or `.`");
    }

    inline for (.{ "ready-fd", "help", "version", "healthcheck" }) |reserved| {
        if (std.mem.eql(u8, definition.name, reserved)) {
            invalidDefinition(definition.name, "name is reserved for a process option or subcommand");
        }
    }
}

fn validateArityAndInput(comptime definition: DirectiveDefinition) void {
    if (definition.arity.maximum) |maximum| {
        if (definition.arity.minimum > maximum) {
            invalidDefinition(definition.name, "minimum arity exceeds maximum arity");
        }
    }

    if (definition.input.file_values == .unsplit_value and !hasExactSingleValue(definition.arity)) {
        invalidDefinition(definition.name, "unsplit file input requires exact arity one");
    }
}

fn validateRepeat(comptime definition: DirectiveDefinition) void {
    switch (definition.repeat) {
        .replace => if (definition.reset != null) {
            invalidDefinition(definition.name, "replacement policy must not have a reset callback");
        },
        .append => {
            if (definition.reset == null) invalidDefinition(definition.name, "append policy requires a reset callback");
            if (definition.state_lifecycle == null) invalidDefinition(definition.name, "append policy requires a state lifecycle");
        },
    }
}

fn validateChoices(comptime definition: DirectiveDefinition) void {
    if (definition.choices) |choices| {
        if (!hasExactSingleValue(definition.arity)) {
            invalidDefinition(definition.name, "choices require exact arity one");
        }
        if (choices.len == 0) invalidDefinition(definition.name, "choices must have a nonempty list");
        inline for (choices, 0..) |choice, index| {
            inline for (choices[index + 1 ..]) |other| {
                if (std.mem.eql(u8, choice, other)) {
                    invalidDefinition(definition.name, "choices contain a duplicate spelling");
                }
            }
        }
    }
}

fn hasExactSingleValue(arity: Arity) bool {
    return arity.minimum == 1 and arity.maximum != null and arity.maximum.? == 1;
}

fn invalidDefinition(comptime name: []const u8, comptime reason: []const u8) noreturn {
    const label = if (name.len == 0) "<empty>" else name;
    @compileError("invalid config directive definition `" ++ label ++ "`: " ++ reason);
}

fn integerDirective(
    comptime name: []const u8,
    comptime field: []const u8,
    comptime T: type,
    comptime minimum: T,
    comptime maximum: T,
) DirectiveDefinition {
    if (@typeInfo(T) != .int) @compileError("integer directive requires an integer type");
    if (minimum > maximum) @compileError("integer directive minimum exceeds maximum");

    const Parser = struct {
        fn parse(value: []const u8) ParseError!T {
            return parseIntegerInRange(T, value, minimum, maximum);
        }
    };
    return singleValueDirective(name, field, valueTagFor(T), Parser.parse);
}

fn parseIntegerInRange(comptime T: type, value: []const u8, minimum: T, maximum: T) ParseError!T {
    const parsed = std.fmt.parseInt(T, value, 10) catch return error.InvalidValue;
    if (parsed < minimum or parsed > maximum) return error.InvalidValue;
    return parsed;
}

fn booleanDirective(comptime name: []const u8, comptime field: []const u8) DirectiveDefinition {
    const Parser = struct {
        fn parse(value: []const u8) ParseError!bool {
            if (std.mem.eql(u8, value, boolean_choices[0])) return true;
            if (std.mem.eql(u8, value, boolean_choices[1])) return false;
            return error.InvalidValue;
        }
    };
    var definition = singleValueDirective(name, field, .boolean, Parser.parse);
    definition.choices = &boolean_choices;
    return definition;
}

fn enumDirective(comptime name: []const u8, comptime field: []const u8, comptime T: type) DirectiveDefinition {
    if (@typeInfo(T) != .@"enum") @compileError("enum directive requires an enum type");

    const Parser = struct {
        const choices: [std.meta.fields(T).len][]const u8 = blk: {
            var names: [std.meta.fields(T).len][]const u8 = undefined;
            for (std.meta.fields(T), 0..) |enum_field, index| names[index] = enum_field.name;
            break :blk names;
        };

        fn parse(value: []const u8) ParseError!T {
            return std.meta.stringToEnum(T, value) orelse error.InvalidValue;
        }
    };
    var definition = singleValueDirective(name, field, valueTagFor(T), Parser.parse);
    definition.choices = &Parser.choices;
    return definition;
}

fn stringDirective(
    comptime name: []const u8,
    comptime field: []const u8,
    comptime validator: ?StringValidator,
) DirectiveDefinition {
    const Parser = struct {
        fn parse(value: []const u8) ParseError![]const u8 {
            if (value.len == 0) return error.InvalidValue;
            if (validator) |validate| try validate(value);
            return value;
        }
    };
    return singleValueDirective(name, field, .string, Parser.parse);
}

fn singleValueDirective(
    comptime name: []const u8,
    comptime field: []const u8,
    comptime tag: ValueTag,
    comptime parse_value: *const fn (value: []const u8) ParseError!@FieldType(Value, @tagName(tag)),
) DirectiveDefinition {
    if (!@hasField(Config, field)) @compileError("unknown Config field `" ++ field ++ "`");

    if (@FieldType(Config, field) != @FieldType(Value, @tagName(tag))) {
        @compileError("Config field `" ++ field ++ "` does not match value tag `" ++ @tagName(tag) ++ "`");
    }

    const Callbacks = struct {
        fn parse(values: []const []const u8) ParseError!Value {
            if (values.len != 1) return error.InvalidArity;
            return @unionInit(Value, @tagName(tag), try parse_value(values[0]));
        }

        fn apply(context: *directive_definition.ApplyContext, value: Value) directive_definition.ApplyError!void {
            @field(context.config, field) = @field(value, @tagName(tag));
        }
    };

    return .{
        .name = name,
        .arity = Arity.exact(1),
        .parse = Callbacks.parse,
        .apply = Callbacks.apply,
    };
}

fn valueTagFor(comptime T: type) ValueTag {
    if (T == u16) return .u16_value;
    if (T == u32) return .u32_value;
    if (T == usize) return .usize_value;
    if (T == i8) return .i8_value;
    if (T == i64) return .i64_value;
    if (T == Config.AppendFsync) return .append_fsync;
    @compileError("unsupported config value type `" ++ @typeName(T) ++ "`");
}

fn saveDirective() DirectiveDefinition {
    const Callbacks = struct {
        fn stateFrom(context: *directive_definition.ApplyContext) *SaveState {
            return @ptrCast(@alignCast(context.state.?));
        }

        fn parse(values: []const []const u8) ParseError!Value {
            if (values.len != 2) return error.InvalidArity;
            return .{ .save = .{ .rule = .{
                .seconds = try parseIntegerInRange(i64, values[0], 1, std.math.maxInt(i64)),
                .changes = try parseIntegerInRange(u32, values[1], 1, std.math.maxInt(u32)),
            } } };
        }

        fn apply(context: *directive_definition.ApplyContext, value: Value) directive_definition.ApplyError!void {
            const state = stateFrom(context);
            std.debug.assert(state.finalized_rules == null);
            try state.rules.append(context.allocator, value.save.rule);
        }

        fn reset(context: *directive_definition.ApplyContext) void {
            const state = stateFrom(context);
            std.debug.assert(state.finalized_rules == null);
            state.rules.clearRetainingCapacity();
        }

        fn init(allocator: std.mem.Allocator) directive_definition.ApplyError!*anyopaque {
            const state = try allocator.create(SaveState);
            state.* = .{};
            return state;
        }

        fn finalize(context: *directive_definition.ApplyContext) directive_definition.BuildError!void {
            const state = stateFrom(context);
            std.debug.assert(state.finalized_rules == null);
            const rules = try state.rules.toOwnedSlice(context.allocator);
            state.finalized_rules = rules;
            context.config.save_rules = rules;
        }

        fn deinit(context: *directive_definition.ApplyContext, mode: directive_definition.CleanupMode) void {
            const state = stateFrom(context);
            state.rules.deinit(context.allocator);
            if (mode == .discard) {
                if (state.finalized_rules) |rules| context.allocator.free(rules);
            }
            context.allocator.destroy(state);
            context.state = null;
        }
    };

    return .{
        .name = "save",
        .arity = Arity.exact(2),
        .input = .{ .file_values = .tokens },
        .repeat = .append,
        .parse = Callbacks.parse,
        .apply = Callbacks.apply,
        .reset = Callbacks.reset,
        .state_lifecycle = .{
            .init = Callbacks.init,
            .finalize = Callbacks.finalize,
            .deinit = Callbacks.deinit,
        },
    };
}

test {
    std.testing.refAllDecls(@This());
}

test "find returns static definitions and matches names case-sensitively" {
    const testing = std.testing;
    const entries = all();
    try testing.expectEqual(21, entries.len);

    for (entries, 0..) |definition, index| {
        try testing.expect(find(definition.name).? == &entries[index]);

        const uppercase = try testing.allocator.dupe(u8, definition.name);
        defer testing.allocator.free(uppercase);
        for (uppercase) |*byte| byte.* = std.ascii.toUpper(byte.*);
        try testing.expect(find(uppercase) == null);
    }

    try testing.expect(find("Port") == null);
    try testing.expect(find("appendOnly") == null);
}

test "find excludes process options, CLI prefixes, and unsupported names" {
    for ([_][]const u8{
        "ready-fd",
        "--ready-fd",
        "healthcheck",
        "--port",
        "num-databases",
        "append-dirname",
        "append-filename",
        "snapshot-path",
        "unknown-option",
        "",
        " port",
        "port ",
    }) |name| {
        try std.testing.expect(find(name) == null);
    }
}

test "single-value preparation and application agree with file parsing for every setting" {
    const testing = std.testing;
    const ConfigParser = @import("../config_parser.zig");
    const cases = [_]struct { line: []const u8, value: Value }{
        .{ .line = "bind example host", .value = .{ .string = "example host" } },
        .{ .line = "port 7000", .value = .{ .u16_value = 7000 } },
        .{ .line = "reuse-address no", .value = .{ .boolean = false } },
        .{ .line = "connection-buffer-size 2048", .value = .{ .usize_value = 2048 } },
        .{ .line = "databases 4", .value = .{ .usize_value = 4 } },
        .{ .line = "dir data files", .value = .{ .string = "data files" } },
        .{ .line = "dbfilename state.kgc", .value = .{ .string = "state.kgc" } },
        .{ .line = "cron-interval-ms 250", .value = .{ .i64_value = 250 } },
        .{ .line = "active-expire-budget-ms 15", .value = .{ .i8_value = 15 } },
        .{ .line = "active-expire-batch-size 30", .value = .{ .i8_value = 30 } },
        .{ .line = "active-expire-threshold-percent 50", .value = .{ .i8_value = 50 } },
        .{ .line = "exclusive-bg-persistence no", .value = .{ .boolean = false } },
        .{ .line = "appendonly yes", .value = .{ .boolean = true } },
        .{ .line = "appendfsync always", .value = .{ .append_fsync = .always } },
        .{ .line = "appenddirname history", .value = .{ .string = "history" } },
        .{ .line = "appendfilename history/journal.aof", .value = .{ .string = "history/journal.aof" } },
        .{ .line = "auto-aof-rewrite-percentage 0", .value = .{ .u32_value = 0 } },
        .{ .line = "auto-aof-rewrite-min-size 2048", .value = .{ .usize_value = 2048 } },
        .{ .line = "aof-load-truncated no", .value = .{ .boolean = false } },
        .{ .line = "bgsave-retry-delay-ms 0", .value = .{ .i64_value = 0 } },
    };

    for (cases) |case| {
        const space = std.mem.indexOfScalar(u8, case.line, ' ').?;
        const definition = find(case.line[0..space]).?;
        var config = Config.default();
        const prepared = try prepare(definition, &.{case.line[space + 1 ..]});
        try testing.expect(prepared.definition == definition);
        try testing.expectEqualDeep(case.value, prepared.value);
        try testing.expectEqualDeep(Config.default(), config);

        var context: directive_definition.ApplyContext = .{
            .allocator = testing.failing_allocator,
            .config = &config,
        };
        try prepared.definition.apply(&context, prepared.value);
        const expected = try ConfigParser.parse(testing.failing_allocator, case.line);
        try testing.expectEqualDeep(expected, config);
    }
}

test "integer callbacks enforce every directive's boundaries and number syntax" {
    const testing = std.testing;
    const cases = [_]struct { name: []const u8, minimum: i128, maximum: i128 }{
        .{ .name = "port", .minimum = 0, .maximum = std.math.maxInt(u16) },
        .{ .name = "connection-buffer-size", .minimum = 1, .maximum = std.math.maxInt(usize) },
        .{ .name = "databases", .minimum = 1, .maximum = @min(std.math.maxInt(u32), std.math.maxInt(usize)) },
        .{ .name = "cron-interval-ms", .minimum = 1, .maximum = std.math.maxInt(i64) },
        .{ .name = "active-expire-budget-ms", .minimum = 1, .maximum = std.math.maxInt(i8) },
        .{ .name = "active-expire-batch-size", .minimum = 1, .maximum = std.math.maxInt(i8) },
        .{ .name = "active-expire-threshold-percent", .minimum = 1, .maximum = 100 },
        .{ .name = "auto-aof-rewrite-percentage", .minimum = 0, .maximum = std.math.maxInt(u32) },
        .{ .name = "auto-aof-rewrite-min-size", .minimum = 0, .maximum = std.math.maxInt(usize) },
        .{ .name = "bgsave-retry-delay-ms", .minimum = 0, .maximum = std.math.maxInt(i64) },
    };

    for (cases) |case| {
        const definition = find(case.name).?;
        try testing.expect(definition.choices == null);
        for ([_]i128{ case.minimum, case.maximum, case.minimum - 1, case.maximum + 1 }) |number| {
            const text = try std.fmt.allocPrint(testing.allocator, "{d}", .{number});
            defer testing.allocator.free(text);
            if (number < case.minimum or number > case.maximum) {
                try testing.expectError(error.InvalidValue, definition.parse(&.{text}));
            } else {
                const value = try definition.parse(&.{text});
                const actual: i128 = switch (value) {
                    .u16_value => |n| n,
                    .u32_value => |n| n,
                    .usize_value => |n| n,
                    .i8_value => |n| n,
                    .i64_value => |n| n,
                    else => return error.UnexpectedValueTag,
                };
                try testing.expectEqual(number, actual);
            }
        }
        for ([_][]const u8{ "", "invalid", "1 2", "1.5", "\"1\"", "1kb", "0x10", "--1" }) |text| {
            try testing.expectError(error.InvalidValue, definition.parse(&.{text}));
        }
    }
}

test "boolean preparation exposes and accepts exact yes and no choices" {
    const testing = std.testing;
    for ([_][]const u8{ "reuse-address", "exclusive-bg-persistence", "appendonly", "aof-load-truncated" }) |name| {
        const definition = find(name).?;
        try testing.expectEqualDeep(&boolean_choices, definition.choices.?);
        try testing.expectEqualDeep(Value{ .boolean = true }, (try prepare(definition, &.{"yes"})).value);
        try testing.expectEqualDeep(Value{ .boolean = false }, (try prepare(definition, &.{"no"})).value);
        for ([_][]const u8{ "", "YES", "No", "true", "false", "1", "0", "\"yes\"", "yes no" }) |text| {
            try testing.expectError(error.InvalidValue, prepare(definition, &.{text}));
        }
    }
}

test "enum preparation exposes tag names and returns typed enum values" {
    const testing = std.testing;
    const definition = find("appendfsync").?;
    const expected_choices = [_][]const u8{ "always", "everysec", "no" };
    try testing.expectEqualDeep(&expected_choices, definition.choices.?);
    for ([_]Config.AppendFsync{ .always, .everysec, .no }) |choice| {
        try testing.expectEqualDeep(Value{ .append_fsync = choice }, (try prepare(definition, &.{@tagName(choice)})).value);
    }
    for ([_][]const u8{ "", "Always", "EVERYSEC", "yes", "invalid", "\"no\"", "no always" }) |text| {
        try testing.expectError(error.InvalidValue, prepare(definition, &.{text}));
    }
}

test "string callbacks borrow input and preserve existing validation" {
    const testing = std.testing;
    var text = "data files".*;
    const definition = find("dir").?;
    const value = try definition.parse(&.{&text});
    try testing.expect(value.string.ptr == text[0..].ptr);

    var config = Config.default();
    var context: directive_definition.ApplyContext = .{
        .allocator = testing.failing_allocator,
        .config = &config,
    };
    try definition.apply(&context, value);
    try testing.expect(config.dir.ptr == text[0..].ptr);
    text[0] = 'D';
    try testing.expectEqualStrings("Data files", config.dir);

    for ([_][]const u8{ "bind", "dir", "dbfilename", "appenddirname", "appendfilename" }) |name| {
        const entry = find(name).?;
        try testing.expect(entry.choices == null);
        try testing.expectError(error.InvalidValue, entry.parse(&.{""}));
    }
    for ([_]struct { name: []const u8, text: []const u8 }{
        .{ .name = "dir", .text = "\"data files\"" },
        .{ .name = "dbfilename", .text = "\"state\".kgc" },
        .{ .name = "appenddirname", .text = "\"history\"" },
        .{ .name = "bind", .text = "not an address" },
        .{ .name = "appendfilename", .text = "history/journal.aof" },
    }) |case| {
        const parsed = try find(case.name).?.parse(&.{case.text});
        try testing.expectEqualStrings(case.text, parsed.string);
        try testing.expect(parsed.string.ptr == case.text.ptr);
    }
    for ([_]struct { name: []const u8, text: []const u8 }{
        .{ .name = "dir", .text = "data\x00files" },
        .{ .name = "dbfilename", .text = "../state.kgc" },
        .{ .name = "dbfilename", .text = "state.rdb" },
        .{ .name = "dbfilename", .text = "history\\state.kgc" },
        .{ .name = "dbfilename", .text = "state\x00.kgc" },
        .{ .name = "appenddirname", .text = "." },
        .{ .name = "appenddirname", .text = ".." },
        .{ .name = "appenddirname", .text = "history/logs" },
        .{ .name = "appenddirname", .text = "history\\logs" },
        .{ .name = "appenddirname", .text = "history\x00" },
    }) |case| {
        try testing.expectError(error.InvalidValue, find(case.name).?.parse(&.{case.text}));
    }
}

test "single-value callbacks reject missing and extra values" {
    for (all()) |definition| {
        if (definition.repeat == .append) continue;
        try std.testing.expectError(error.InvalidArity, definition.parse(&.{}));
        try std.testing.expectError(error.InvalidArity, definition.parse(&.{ "1", "2" }));
    }
}

test "prepare checks arity and choices before parsing and never applies" {
    const Probe = struct {
        var parse_calls: usize = 0;

        fn parse(values: []const []const u8) ParseError!Value {
            parse_calls += 1;
            return .{ .boolean = std.mem.eql(u8, values[0], "yes") };
        }

        fn apply(_: *directive_definition.ApplyContext, _: Value) directive_definition.ApplyError!void {
            @panic("preparation must not apply a directive");
        }
    };
    const definition = comptime DirectiveDefinition{
        .name = "choice-probe",
        .arity = Arity.exact(1),
        .choices = &.{ "yes", "no" },
        .parse = Probe.parse,
        .apply = Probe.apply,
    };
    comptime validateDefinitions(&.{definition});
    Probe.parse_calls = 0;
    const testing = std.testing;
    try testing.expectError(error.InvalidArity, prepare(&definition, &.{}));
    try testing.expectError(error.InvalidArity, prepare(&definition, &.{ "invalid", "yes" }));
    try testing.expectError(error.InvalidValue, prepare(&definition, &.{"YES"}));
    try testing.expectEqual(0, Probe.parse_calls);

    const prepared = try prepare(&definition, &.{"yes"});
    try testing.expect(prepared.definition == &definition);
    try testing.expectEqualDeep(Value{ .boolean = true }, prepared.value);
    try testing.expectEqual(1, Probe.parse_calls);
}

test "prepare leaves numeric and path constraints active with null choices" {
    const testing = std.testing;
    for ([_]struct { name: []const u8, value: []const u8 }{
        .{ .name = "port", .value = "65536" },
        .{ .name = "connection-buffer-size", .value = "0" },
        .{ .name = "dir", .value = "data\x00files" },
        .{ .name = "dbfilename", .value = "../state.kgc" },
        .{ .name = "appenddirname", .value = ".." },
    }) |case| {
        const definition = find(case.name).?;
        try testing.expect(definition.choices == null);
        try testing.expectError(error.InvalidValue, prepare(definition, &.{case.value}));
    }

    const definition = comptime blk: {
        var entry = integerDirective("limited-port", "port", u16, 0, 100);
        entry.choices = &.{ "50", "200" };
        break :blk entry;
    };
    comptime validateDefinitions(&.{definition});
    try testing.expectEqualDeep(Value{ .u16_value = 50 }, (try prepare(&definition, &.{"50"})).value);
    try testing.expectError(error.InvalidValue, prepare(&definition, &.{"200"}));
}

test "prepare borrows string storage and copies save numbers independently of token arrays" {
    const testing = std.testing;
    var text = "data files".*;
    var string_values = [_][]const u8{&text};
    const string_prepared = try prepare(find("dir").?, &string_values);
    string_values[0] = "other";
    try testing.expect(string_prepared.value.string.ptr == text[0..].ptr);
    text[0] = 'D';
    try testing.expectEqualStrings("Data files", string_prepared.value.string);

    var seconds = "60".*;
    var changes = "1".*;
    var save_values = [_][]const u8{ &seconds, &changes };
    const definition = find("save").?;
    const prepared = try prepare(definition, &save_values);
    seconds[0] = '9';
    changes[0] = '2';
    save_values = .{ "300", "10" };
    try testing.expect(prepared.definition == definition);
    try testing.expectEqualDeep(
        Value{ .save = .{ .rule = .{ .seconds = 60, .changes = 1 } } },
        prepared.value,
    );
    try testing.expectError(error.InvalidArity, prepare(definition, &.{"60"}));
    try testing.expectError(error.InvalidArity, prepare(definition, &.{ "60", "1", "2" }));
    try testing.expectError(error.InvalidValue, prepare(definition, &.{ "0", "1" }));
}

test "prepare supports exact, bounded, and unbounded token counts above two" {
    const Parser = struct {
        fn parse(values: []const []const u8) ParseError!Value {
            return .{ .usize_value = values.len };
        }

        fn apply(_: *directive_definition.ApplyContext, _: Value) directive_definition.ApplyError!void {
            @panic("preparation must not apply a directive");
        }
    };
    const testing = std.testing;
    inline for (comptime .{ Arity.exact(3), Arity.range(3, 5), Arity.atLeast(3) }) |arity| {
        const definition = comptime DirectiveDefinition{
            .name = "count-probe",
            .arity = arity,
            .input = .{ .file_values = .tokens },
            .parse = Parser.parse,
            .apply = Parser.apply,
        };
        comptime validateDefinitions(&.{definition});
        try testing.expectError(error.InvalidArity, prepare(&definition, &.{ "one", "two" }));
        try testing.expectEqualDeep(
            Value{ .usize_value = 3 },
            (try prepare(&definition, &.{ "one", "two", "three" })).value,
        );
        if (arity.accepts(5)) {
            try testing.expectEqualDeep(
                Value{ .usize_value = 5 },
                (try prepare(&definition, &.{ "one", "two", "three", "four", "five" })).value,
            );
        } else {
            try testing.expectError(error.InvalidArity, prepare(&definition, &.{ "one", "two", "three", "four", "five" }));
        }
    }
}

test "save parser accepts exactly two positive numbers without enabling clearing" {
    const testing = std.testing;
    const definition = find("save").?;
    try testing.expectEqualDeep(Arity.exact(2), definition.arity);
    try testing.expectEqual(.tokens, definition.input.file_values);
    try testing.expectEqual(.append, definition.repeat);
    try testing.expect(definition.choices == null);
    try testing.expect(definition.input.cli_value_count == null);
    try testing.expect(!definition.input.normalize_empty_file_value);

    try testing.expectEqualDeep(
        Value{ .save = .{ .rule = .{ .seconds = 1, .changes = 1 } } },
        try definition.parse(&.{ "1", "1" }),
    );
    try testing.expectEqualDeep(
        Value{ .save = .{ .rule = .{ .seconds = std.math.maxInt(i64), .changes = std.math.maxInt(u32) } } },
        try definition.parse(&.{ "9223372036854775807", "4294967295" }),
    );
    for ([_][]const []const u8{ &.{}, &.{"60"}, &.{""}, &.{"\"\""}, &.{ "60", "1", "2" } }) |values| {
        try testing.expectError(error.InvalidArity, definition.parse(values));
    }
    for ([_][2][]const u8{
        .{ "0", "1" },
        .{ "-1", "1" },
        .{ "9223372036854775808", "1" },
        .{ "1", "0" },
        .{ "1", "-1" },
        .{ "1", "4294967296" },
        .{ "invalid", "1" },
        .{ "1", "invalid" },
        .{ "", "1" },
        .{ "1", "" },
        .{ "1.5", "1" },
        .{ "1", "\"1\"" },
        .{ "60 1", "1" },
    }) |values| {
        try testing.expectError(error.InvalidValue, definition.parse(&values));
    }
}

test "save callbacks collect rules in order and retain finalized output for Config" {
    const testing = std.testing;
    const definition = find("save").?;
    const lifecycle = definition.state_lifecycle.?;
    var config = Config.default();
    config.port = 7000;
    var context: directive_definition.ApplyContext = .{
        .allocator = testing.allocator,
        .config = &config,
        .state = try lifecycle.init(testing.allocator),
    };
    defer if (context.state != null) lifecycle.deinit(&context, .discard);

    const expected_rules = [_]Config.SaveRule{
        .{ .seconds = 900, .changes = 1 },
        .{ .seconds = 300, .changes = 10 },
        .{ .seconds = 60, .changes = 10000 },
    };
    for ([_][2][]const u8{ .{ "900", "1" }, .{ "300", "10" }, .{ "60", "10000" } }) |values| {
        try definition.apply(&context, try definition.parse(&values));
        try testing.expectEqual(0, config.save_rules.len);
    }
    try lifecycle.finalize(&context);
    const state: *SaveState = @ptrCast(@alignCast(context.state.?));
    try testing.expect(state.finalized_rules.?.ptr == config.save_rules.ptr);
    try testing.expectEqual(0, state.rules.items.len);

    lifecycle.deinit(&context, .retain_config);
    defer testing.allocator.free(config.save_rules);
    var expected = Config.default();
    expected.port = 7000;
    expected.save_rules = &expected_rules;
    try testing.expectEqualDeep(expected, config);
}

test "save reset clears only its collection and reuses its allocation" {
    const testing = std.testing;
    const definition = find("save").?;
    const lifecycle = definition.state_lifecycle.?;
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const allocator = failing.allocator();
    var config = Config.default();
    config.port = 7000;
    config.append_only = true;
    var context: directive_definition.ApplyContext = .{
        .allocator = allocator,
        .config = &config,
        .state = try lifecycle.init(allocator),
    };
    defer if (context.state != null) lifecycle.deinit(&context, .discard);

    try definition.apply(&context, try definition.parse(&.{ "60", "1" }));
    try definition.apply(&context, try definition.parse(&.{ "300", "10" }));
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = 0;
    definition.reset.?(&context);
    try definition.apply(&context, try definition.parse(&.{ "900", "100" }));
    try testing.expect(!failing.has_induced_failure);
    try testing.expectEqual(0, config.save_rules.len);

    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
    try lifecycle.finalize(&context);
    lifecycle.deinit(&context, .retain_config);
    defer allocator.free(config.save_rules);
    var expected = Config.default();
    expected.port = 7000;
    expected.append_only = true;
    expected.save_rules = &.{.{ .seconds = 900, .changes = 100 }};
    try testing.expectEqualDeep(expected, config);
}

test "save state is separate for each initialization" {
    const testing = std.testing;
    const definition = find("save").?;
    const lifecycle = definition.state_lifecycle.?;
    var first_config = Config.default();
    var first: directive_definition.ApplyContext = .{
        .allocator = testing.allocator,
        .config = &first_config,
        .state = try lifecycle.init(testing.allocator),
    };
    defer if (first.state != null) lifecycle.deinit(&first, .discard);
    var second_config = Config.default();
    var second: directive_definition.ApplyContext = .{
        .allocator = testing.allocator,
        .config = &second_config,
        .state = try lifecycle.init(testing.allocator),
    };
    defer if (second.state != null) lifecycle.deinit(&second, .discard);

    try testing.expect(first.state.? != second.state.?);
    try definition.apply(&first, try definition.parse(&.{ "60", "1" }));
    try definition.apply(&second, try definition.parse(&.{ "300", "10" }));
    definition.reset.?(&first);
    try lifecycle.finalize(&first);
    try testing.expectEqual(0, first_config.save_rules.len);
    lifecycle.deinit(&first, .discard);

    try lifecycle.finalize(&second);
    lifecycle.deinit(&second, .retain_config);
    defer testing.allocator.free(second_config.save_rules);
    try testing.expectEqualDeep(
        &[_]Config.SaveRule{.{ .seconds = 300, .changes = 10 }},
        second_config.save_rules,
    );
}

test "save discard releases unfinished rules and already finalized output" {
    const testing = std.testing;
    const definition = find("save").?;
    const lifecycle = definition.state_lifecycle.?;
    for ([_]bool{ false, true }) |finalize| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{});
        const allocator = failing.allocator();
        var config = Config.default();
        var context: directive_definition.ApplyContext = .{
            .allocator = allocator,
            .config = &config,
            .state = try lifecycle.init(allocator),
        };
        defer if (context.state != null) lifecycle.deinit(&context, .discard);
        try definition.apply(&context, try definition.parse(&.{ "60", "1" }));
        if (finalize) {
            try lifecycle.finalize(&context);
            try testing.expectEqual(1, config.save_rules.len);
        }
        lifecycle.deinit(&context, .discard);
        try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

test "save can finalize an empty or reset collection without allocating" {
    const testing = std.testing;
    const definition = find("save").?;
    const lifecycle = definition.state_lifecycle.?;
    for ([_]bool{ false, true }) |append_then_reset| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{});
        const allocator = failing.allocator();
        var config = Config.default();
        var context: directive_definition.ApplyContext = .{
            .allocator = allocator,
            .config = &config,
            .state = try lifecycle.init(allocator),
        };
        defer if (context.state != null) lifecycle.deinit(&context, .discard);
        if (append_then_reset) {
            try definition.apply(&context, try definition.parse(&.{ "60", "1" }));
            definition.reset.?(&context);
        }
        failing.fail_index = failing.alloc_index;
        failing.resize_fail_index = 0;
        try lifecycle.finalize(&context);
        try testing.expectEqual(0, config.save_rules.len);
        try testing.expect(!failing.has_induced_failure);
        lifecycle.deinit(&context, .retain_config);
        allocator.free(config.save_rules);
        try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

test "save finalization failure leaves the collected rules owned for discard" {
    const testing = std.testing;
    const definition = find("save").?;
    const lifecycle = definition.state_lifecycle.?;
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .resize_fail_index = 0 });
    const allocator = failing.allocator();
    var config = Config.default();
    var context: directive_definition.ApplyContext = .{
        .allocator = allocator,
        .config = &config,
        .state = try lifecycle.init(allocator),
    };
    defer if (context.state != null) lifecycle.deinit(&context, .discard);
    try definition.apply(&context, try definition.parse(&.{ "60", "1" }));
    const state: *SaveState = @ptrCast(@alignCast(context.state.?));
    try state.rules.ensureUnusedCapacity(allocator, 1);
    failing.fail_index = failing.alloc_index;

    try testing.expectError(error.OutOfMemory, lifecycle.finalize(&context));
    try testing.expectEqual(0, config.save_rules.len);
    try testing.expect(state.finalized_rules == null);
    try testing.expectEqualDeep(
        &[_]Config.SaveRule{.{ .seconds = 60, .changes = 1 }},
        state.rules.items,
    );
    lifecycle.deinit(&context, .discard);
    try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

test "save lifecycle cleans up every allocation failure during init, growth, and finalization" {
    const Run = struct {
        fn run(backing_allocator: std.mem.Allocator, mode: directive_definition.CleanupMode) !void {
            var failing_resize = std.testing.FailingAllocator.init(backing_allocator, .{ .resize_fail_index = 0 });
            const allocator = failing_resize.allocator();
            const definition = find("save").?;
            const lifecycle = definition.state_lifecycle.?;
            var config = Config.default();
            var context: directive_definition.ApplyContext = .{
                .allocator = allocator,
                .config = &config,
                .state = try lifecycle.init(allocator),
            };
            defer if (context.state != null) lifecycle.deinit(&context, .discard);
            for (0..64) |index| {
                try definition.apply(&context, .{ .save = .{ .rule = .{
                    .seconds = @intCast(index + 1),
                    .changes = @intCast(index + 1),
                } } });
            }
            const state: *SaveState = @ptrCast(@alignCast(context.state.?));
            try state.rules.ensureUnusedCapacity(allocator, 1);
            try lifecycle.finalize(&context);
            try std.testing.expectEqual(64, config.save_rules.len);
            lifecycle.deinit(&context, mode);
            if (mode == .retain_config) {
                defer allocator.free(config.save_rules);
                for (config.save_rules, 0..) |rule, index| {
                    try std.testing.expectEqual(@as(i64, @intCast(index + 1)), rule.seconds);
                    try std.testing.expectEqual(@as(u32, @intCast(index + 1)), rule.changes);
                }
            }
        }
    };
    for ([_]directive_definition.CleanupMode{ .discard, .retain_config }) |mode| {
        try std.testing.checkAllAllocationFailures(std.testing.allocator, Run.run, .{mode});
    }
}
