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
    .{
        .name = "save",
        .arity = Arity.exact(2),
        .input = .{ .file_values = .tokens },
        .repeat = .append,
        .parse = parseStub,
        .apply = applyStub,
        .reset = resetStub,
        .state_lifecycle = .{
            .init = initStateStub,
            .finalize = finalizeStateStub,
            .deinit = deinitStateStub,
        },
    },
    booleanDirective("appendonly", "append_only"),
    enumDirective("appendfsync", "append_fsync", Config.AppendFsync),
    stringDirective("appenddirname", "append_dirname", Config.validateAppendDirname),
    stringDirective("appendfilename", "append_filename", null),
    integerDirective("auto-aof-rewrite-percentage", "auto_aof_rewrite_percentage", u32, 0, std.math.maxInt(u32)),
    integerDirective("auto-aof-rewrite-min-size", "auto_aof_rewrite_min_size", usize, 0, std.math.maxInt(usize)),
    booleanDirective("aof-load-truncated", "aof_load_truncated"),
    integerDirective("bgsave-retry-delay-ms", "bgsave_retry_delay_ms", i64, 0, std.math.maxInt(i64)),
};

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
    _ = definition;
    _ = values;
    @panic("config directive preparation is not implemented");
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
            const parsed = std.fmt.parseInt(T, value, 10) catch return error.InvalidValue;
            if (parsed < minimum or parsed > maximum) return error.InvalidValue;
            return parsed;
        }
    };
    return singleValueDirective(name, field, valueTagFor(T), Parser.parse);
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

fn parseStub(values: []const []const u8) directive_definition.ParseError!directive_definition.Value {
    _ = values;
    @panic("config directive parsing is not implemented");
}

fn applyStub(context: *directive_definition.ApplyContext, value: directive_definition.Value) directive_definition.ApplyError!void {
    _ = context;
    _ = value;
    @panic("config directive application is not implemented");
}

fn resetStub(context: *directive_definition.ApplyContext) void {
    _ = context;
    @panic("config directive reset is not implemented");
}

fn initStateStub(allocator: std.mem.Allocator) directive_definition.ApplyError!*anyopaque {
    _ = allocator;
    @panic("config directive state initialization is not implemented");
}

fn finalizeStateStub(context: *directive_definition.ApplyContext) directive_definition.BuildError!void {
    _ = context;
    @panic("config directive state finalization is not implemented");
}

fn deinitStateStub(context: *directive_definition.ApplyContext, mode: directive_definition.CleanupMode) void {
    _ = context;
    _ = mode;
    @panic("config directive state cleanup is not implemented");
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

test "single-value callbacks match the existing file parser for every setting" {
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
        const value = try definition.parse(&.{case.line[space + 1 ..]});
        try testing.expectEqualDeep(case.value, value);

        var config = Config.default();
        var context: directive_definition.ApplyContext = .{
            .allocator = testing.failing_allocator,
            .config = &config,
        };
        try definition.apply(&context, value);
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

test "boolean callbacks expose and accept exact yes and no choices" {
    const testing = std.testing;
    for ([_][]const u8{ "reuse-address", "exclusive-bg-persistence", "appendonly", "aof-load-truncated" }) |name| {
        const definition = find(name).?;
        try testing.expectEqualDeep(&boolean_choices, definition.choices.?);
        try testing.expectEqualDeep(Value{ .boolean = true }, try definition.parse(&.{"yes"}));
        try testing.expectEqualDeep(Value{ .boolean = false }, try definition.parse(&.{"no"}));
        for ([_][]const u8{ "", "YES", "No", "true", "false", "1", "0", "\"yes\"", "yes no" }) |text| {
            try testing.expectError(error.InvalidValue, definition.parse(&.{text}));
        }
    }
}

test "enum callbacks expose tag names and return typed enum values" {
    const testing = std.testing;
    const definition = find("appendfsync").?;
    const expected_choices = [_][]const u8{ "always", "everysec", "no" };
    try testing.expectEqualDeep(&expected_choices, definition.choices.?);
    for ([_]Config.AppendFsync{ .always, .everysec, .no }) |choice| {
        try testing.expectEqualDeep(Value{ .append_fsync = choice }, try definition.parse(&.{@tagName(choice)}));
    }
    for ([_][]const u8{ "", "Always", "EVERYSEC", "yes", "invalid", "\"no\"", "no always" }) |text| {
        try testing.expectError(error.InvalidValue, definition.parse(&.{text}));
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
