const std = @import("std");
const resp = @import("../resp.zig");
const store = @import("../store.zig");
const command_arguments = @import("arguments.zig");
const definition = @import("definition.zig");
const registry = @import("registry.zig");
const Commander = @import("interface.zig");

const Command = @This();
const Value = resp.RESPValue;

const Subcommand = enum {
    count,
    list,
    info,
    getkeys,
    getkeysandflags,
};

allocator: std.mem.Allocator,
arguments: []resp.RESPValue,

pub fn commander(self: *Command) Commander {
    return .{ .ptr = self, .vtable = &vtable };
}

const vtable = Commander.VTable{ .execute = execute, .deinit = deinit };

fn execute(ptr: *anyopaque, _: std.Io, _: *store.Store, _: *Commander.ClientState) Commander.Error!Commander.Result {
    const self: *Command = @ptrCast(@alignCast(ptr));
    if (self.arguments.len == 0) return self.executeAll();

    const name = try command_arguments.bulkString(self.arguments[0]);

    return self.executeSubcommand(try parseSubcommand(name));
}

fn parseSubcommand(name: []const u8) Commander.Error!Subcommand {
    if (std.ascii.eqlIgnoreCase(name, "COUNT")) return .count;
    if (std.ascii.eqlIgnoreCase(name, "LIST")) return .list;
    if (std.ascii.eqlIgnoreCase(name, "INFO")) return .info;
    if (std.ascii.eqlIgnoreCase(name, "GETKEYS")) return .getkeys;
    if (std.ascii.eqlIgnoreCase(name, "GETKEYSANDFLAGS")) return .getkeysandflags;
    return error.UnsupportedOption;
}

fn executeSubcommand(self: *Command, subcommand: Subcommand) Commander.Error!Commander.Result {
    return switch (subcommand) {
        .count => self.executeCount(),
        .list => self.executeList(),
        .info => self.executeInfo(),
        .getkeys => self.executeGetKeys(),
        .getkeysandflags => self.executeGetKeysAndFlags(),
    };
}

const ResponseKind = enum { all, list, info, getkeys, getkeysandflags };

fn executeAll(self: *Command) Commander.Error!Commander.Result {
    return self.reply(.all);
}

fn executeCount(self: *Command) Commander.Error!Commander.Result {
    if (self.arguments.len != 1) return error.WrongNumberArguments;
    return Commander.Result.borrowed(.{ .integer = @intCast(registry.all().len) });
}

fn executeList(self: *Command) Commander.Error!Commander.Result {
    return self.reply(.list);
}

fn executeInfo(self: *Command) Commander.Error!Commander.Result {
    return self.reply(.info);
}

fn executeGetKeys(self: *Command) Commander.Error!Commander.Result {
    return self.reply(.getkeys);
}

fn executeGetKeysAndFlags(self: *Command) Commander.Error!Commander.Result {
    return self.reply(.getkeysandflags);
}

fn reply(self: *Command, kind: ResponseKind) Commander.Error!Commander.Result {
    const arena = try self.allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(self.allocator);
    errdefer {
        arena.deinit();
        self.allocator.destroy(arena);
    }

    const allocator = arena.allocator();
    const value = switch (kind) {
        .all => try allInfo(allocator),
        .list => try list(allocator, self.arguments[1..]),
        .info => try info(allocator, self.arguments[1..]),
        .getkeys => try getKeys(allocator, self.arguments[1..], false),
        .getkeysandflags => try getKeys(allocator, self.arguments[1..], true),
    };
    return Commander.Result.inArena(value, arena);
}

fn allInfo(allocator: std.mem.Allocator) Commander.Error!Value {
    const definitions = registry.all();
    const items = try allocator.alloc(Value, definitions.len);
    for (definitions, 0..) |*item, index| items[index] = try describe(allocator, item);
    return .{ .array = items };
}

fn info(allocator: std.mem.Allocator, names: []const Value) Commander.Error!Value {
    if (names.len == 0) return allInfo(allocator);

    const items = try allocator.alloc(Value, names.len);
    for (names, 0..) |name, index| {
        const command_name = try command_arguments.bulkString(name);
        items[index] = if (registry.find(command_name)) |item|
            try describe(allocator, item)
        else
            .{ .array = null };
    }
    return .{ .array = items };
}

const ListFilter = union(enum) {
    all,
    pattern: []const u8,
    category: definition.Category,
};

fn list(allocator: std.mem.Allocator, args: []const Value) Commander.Error!Value {
    var filter: ListFilter = .all;
    if (args.len != 0) {
        if (args.len != 3) return error.WrongNumberArguments;
        if (!std.ascii.eqlIgnoreCase(try command_arguments.bulkString(args[0]), "FILTERBY")) return error.Syntax;
        const kind = try command_arguments.bulkString(args[1]);
        const value = try command_arguments.bulkString(args[2]);
        if (std.ascii.eqlIgnoreCase(kind, "PATTERN")) {
            filter = .{ .pattern = value };
        } else if (std.ascii.eqlIgnoreCase(kind, "ACLCAT")) {
            const category_name = if (std.mem.startsWith(u8, value, "@")) value[1..] else value;
            filter = .{ .category = parseCategory(category_name) orelse return error.Syntax };
        } else {
            return error.UnsupportedOption;
        }
    }

    var names: std.ArrayList(Value) = .empty;
    for (registry.all()) |item| {
        const matches = switch (filter) {
            .all => true,
            .pattern => |pattern| matchesPattern(pattern, item.name),
            .category => |category| std.mem.indexOfScalar(definition.Category, item.categories, category) != null,
        };
        if (matches) try names.append(allocator, bulk(item.name));
    }
    return .{ .array = try names.toOwnedSlice(allocator) };
}

fn parseCategory(name: []const u8) ?definition.Category {
    inline for (std.meta.fields(definition.Category)) |field| {
        if (std.ascii.eqlIgnoreCase(name, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

fn matchesPattern(pattern: []const u8, name: []const u8) bool {
    var pattern_index: usize = 0;
    var name_index: usize = 0;
    var star_pattern: ?usize = null;
    var star_name: usize = 0;
    while (name_index < name.len) {
        if (pattern_index < pattern.len and (pattern[pattern_index] == '?' or pattern[pattern_index] == name[name_index])) {
            pattern_index += 1;
            name_index += 1;
        } else if (pattern_index < pattern.len and pattern[pattern_index] == '*') {
            star_pattern = pattern_index;
            pattern_index += 1;
            star_name = name_index;
        } else if (star_pattern) |star| {
            pattern_index = star + 1;
            star_name += 1;
            name_index = star_name;
        } else return false;
    }
    while (pattern_index < pattern.len and pattern[pattern_index] == '*') : (pattern_index += 1) {}
    return pattern_index == pattern.len;
}

fn getKeys(allocator: std.mem.Allocator, args: []const Value, with_flags: bool) Commander.Error!Value {
    if (args.len == 0) return error.WrongNumberArguments;
    const name = try command_arguments.bulkString(args[0]);
    const command_definition = registry.find(name) orelse return error.UnknownCommand;
    const command_args = args[1..];
    if (!command_definition.arity.accepts(command_args.len)) return error.WrongNumberArguments;
    for (command_args) |arg| _ = try command_arguments.bulkString(arg);

    const range = switch (command_definition.keys) {
        .none => return error.Syntax,
        .range => |key_range| key_range,
    };
    const last = switch (range.last) {
        .index => |index| index,
        .remaining => command_args.len - 1,
    };
    const flags = if (with_flags) try keyFlags(allocator, command_definition, command_args) else undefined;
    var keys: std.ArrayList(Value) = .empty;
    var index = range.first;
    while (index <= last) : (index += range.step) {
        const key = command_args[index];
        if (with_flags) {
            try keys.append(allocator, try array(allocator, &.{ key, flags }));
        } else {
            try keys.append(allocator, key);
        }
    }
    return .{ .array = try keys.toOwnedSlice(allocator) };
}

fn keyFlags(allocator: std.mem.Allocator, item: *const definition.Definition, args: []const Value) Commander.Error!Value {
    if (std.mem.eql(u8, item.name, "set")) {
        for (args[2..]) |arg| {
            if (std.ascii.eqlIgnoreCase(try command_arguments.bulkString(arg), "GET")) {
                return array(allocator, &.{ bulk("RW"), bulk("access"), bulk("update") });
            }
        }
        return array(allocator, &.{ bulk("OW"), bulk("update") });
    }
    return switch (item.keys) {
        .none => unreachable,
        .range => |range| flagValues(allocator, range.flags, false),
    };
}

fn describe(allocator: std.mem.Allocator, item: *const definition.Definition) Commander.Error!Value {
    const flags = try allocator.alloc(Value, item.flags.len);
    for (item.flags, 0..) |flag, index| flags[index] = bulk(@tagName(flag));

    const categories = try allocator.alloc(Value, item.categories.len);
    for (item.categories, 0..) |category, index| {
        const name = @tagName(category);
        const with_at = try allocator.alloc(u8, name.len + 1);
        with_at[0] = '@';
        @memcpy(with_at[1..], name);
        categories[index] = bulk(with_at);
    }

    var first: i64 = 0;
    var last: i64 = 0;
    var step: i64 = 0;
    var specs = try array(allocator, &.{});
    switch (item.keys) {
        .none => {},
        .range => |range| {
            first = @intCast(range.first + 1);
            last = switch (range.last) {
                .index => |index| @intCast(index + 1),
                .remaining => -1,
            };
            step = @intCast(range.step);
            const spec_flags = try flagValues(allocator, range.flags, true);
            const begin_spec = try array(allocator, &.{ bulk("index"), .{ .integer = first } });
            const begin_search = try array(allocator, &.{ bulk("type"), bulk("index"), bulk("spec"), begin_spec });
            const relative_last: i64 = switch (range.last) {
                .index => |index| @intCast(index - range.first),
                .remaining => -1,
            };
            const find_spec = try array(allocator, &.{ bulk("lastkey"), .{ .integer = relative_last }, bulk("keystep"), .{ .integer = step }, bulk("limit"), .{ .integer = 0 } });
            const find_keys = try array(allocator, &.{ bulk("type"), bulk("range"), bulk("spec"), find_spec });
            const key_spec = try array(allocator, &.{ bulk("flags"), spec_flags, bulk("begin_search"), begin_search, bulk("find_keys"), find_keys });
            specs = try array(allocator, &.{key_spec});
        },
    }

    return array(allocator, &.{
        bulk(item.name),
        .{ .integer = item.arity.redisValue() },
        .{ .array = flags },
        .{ .integer = first },
        .{ .integer = last },
        .{ .integer = step },
        .{ .array = categories },
        try array(allocator, &.{}),
        specs,
        try array(allocator, &.{}),
    });
}

fn flagValues(allocator: std.mem.Allocator, flags: []const definition.KeyFlag, include_variable: bool) std.mem.Allocator.Error!Value {
    var values: std.ArrayList(Value) = .empty;
    for (flags) |flag| {
        if (flag != .variable_flags or include_variable) try values.append(allocator, bulk(@tagName(flag)));
    }
    return .{ .array = try values.toOwnedSlice(allocator) };
}

fn bulk(value: []const u8) Value {
    return .{ .bulk_string = value };
}

fn array(allocator: std.mem.Allocator, values: []const Value) std.mem.Allocator.Error!Value {
    return .{ .array = try allocator.dupe(Value, values) };
}

fn deinit(ptr: *anyopaque) void {
    const self: *Command = @ptrCast(@alignCast(ptr));
    self.allocator.destroy(self);
}
