const std = @import("std");
const resp = @import("../resp.zig");
const BgRewriteAof = @import("bgrewriteaof.zig");
const BgSave = @import("bgsave.zig");
const Command = @import("command.zig");
const DBSize = @import("dbsize.zig");
const Del = @import("del.zig");
const Echo = @import("echo.zig");
const Get = @import("get.zig");
const Commander = @import("interface.zig");
const Ping = @import("ping.zig");
const Save = @import("save.zig");
const Select = @import("select.zig");
const Set = @import("set.zig");
const command_definition = @import("definition.zig");

const Arity = command_definition.Arity;
const Definition = command_definition.Definition;
const Factory = command_definition.Factory;

pub fn find(name: []const u8) ?*const Definition {
    for (0..definitions.len) |index| {
        const definition = &definitions[index];
        if (std.ascii.eqlIgnoreCase(name, definition.name)) return definition;
    }
    return null;
}

pub fn all() []const Definition {
    return definitions[0..];
}

fn factoryFor(comptime T: type) Factory {
    return struct {
        fn create(allocator: std.mem.Allocator, arguments: []resp.RESPValue) Commander.Error!Commander {
            const implementation = try allocator.create(T);
            implementation.* = .{
                .allocator = allocator,
                .arguments = arguments,
            };
            return implementation.commander();
        }
    }.create;
}

const definitions = [_]Definition{
    .{
        .name = "bgrewriteaof",
        .arity = Arity.exact(0),
        .flags = &.{.admin},
        .categories = &.{ .admin, .slow, .dangerous },
        .keys = .none,
        .factory = factoryFor(BgRewriteAof),
    },
    .{
        .name = "bgsave",
        .arity = Arity.range(0, 1),
        .flags = &.{.admin},
        .categories = &.{ .admin, .slow, .dangerous },
        .keys = .none,
        .factory = factoryFor(BgSave),
    },
    .{
        .name = "command",
        .arity = Arity.atLeast(0),
        .flags = &.{.fast},
        .categories = &.{ .connection, .fast },
        .keys = .none,
        .factory = factoryFor(Command),
    },
    .{
        .name = "dbsize",
        .arity = Arity.exact(0),
        .flags = &.{ .readonly, .fast },
        .categories = &.{ .keyspace, .read, .fast },
        .keys = .none,
        .factory = factoryFor(DBSize),
    },
    .{
        .name = "del",
        .arity = Arity.atLeast(1),
        .flags = &.{.write},
        .categories = &.{ .keyspace, .write, .slow },
        .keys = .{
            .range = .{
                .first = 0,
                .last = .remaining,
                .step = 1,
                .flags = &.{ .RM, .delete },
            },
        },
        .factory = factoryFor(Del),
    },
    .{
        .name = "echo",
        .arity = Arity.exact(1),
        .flags = &.{.fast},
        .categories = &.{ .connection, .fast },
        .keys = .none,
        .factory = factoryFor(Echo),
    },
    .{
        .name = "get",
        .arity = Arity.exact(1),
        .flags = &.{ .readonly, .fast },
        .categories = &.{ .read, .string, .fast },
        .keys = .{
            .range = .{
                .first = 0,
                .last = .{ .index = 0 },
                .step = 1,
                .flags = &.{ .RO, .access },
            },
        },
        .factory = factoryFor(Get),
    },
    .{
        .name = "ping",
        .arity = Arity.range(0, 1),
        .flags = &.{.fast},
        .categories = &.{ .connection, .fast },
        .keys = .none,
        .factory = factoryFor(Ping),
    },
    .{
        .name = "save",
        .arity = Arity.exact(0),
        .flags = &.{.admin},
        .categories = &.{ .admin, .slow, .dangerous },
        .keys = .none,
        .factory = factoryFor(Save),
    },
    .{
        .name = "select",
        .arity = Arity.exact(1),
        .flags = &.{.fast},
        .categories = &.{ .connection, .fast },
        .keys = .none,
        .factory = factoryFor(Select),
    },
    .{
        .name = "set",
        .arity = Arity.atLeast(2),
        .flags = &.{.write},
        .categories = &.{ .write, .string, .slow },
        .keys = .{
            .range = .{
                .first = 0,
                .last = .{ .index = 0 },
                .step = 1,
                .flags = &.{ .RW, .access, .update, .variable_flags },
            },
        },
        .factory = factoryFor(Set),
    },
};

comptime {
    validateDefinitions();
}

fn validateDefinitions() void {
    inline for (definitions, 0..) |definition, index| {
        validateName(definition);
        validateArity(definition);
        validateKeys(definition);

        inline for (definitions, 0..) |other, other_index| {
            if (other_index > index and std.ascii.eqlIgnoreCase(definition.name, other.name)) {
                invalidDefinition(definition.name, "duplicates command `" ++ other.name ++ "`");
            }
        }
    }
}

fn validateName(comptime definition: Definition) void {
    if (definition.name.len == 0) invalidDefinition(definition.name, "has an empty name");

    inline for (definition.name) |byte| {
        const valid = std.ascii.isLower(byte) or
            std.ascii.isDigit(byte) or
            byte == '_' or
            byte == '-' or
            byte == '.';
        if (!valid) invalidDefinition(definition.name, "name must be lowercase ASCII");
    }
}

fn validateArity(comptime definition: Definition) void {
    if (definition.arity.maximum) |maximum| {
        if (definition.arity.minimum > maximum) {
            invalidDefinition(definition.name, "minimum arity exceeds maximum arity");
        }
    }
}

fn validateKeys(comptime definition: Definition) void {
    switch (definition.keys) {
        .none => {},
        .range => |key_range| {
            if (key_range.step == 0) invalidDefinition(definition.name, "key step must be greater than zero");
            if (key_range.flags.len == 0) invalidDefinition(definition.name, "key flags must not be empty");
            if (key_range.first >= definition.arity.minimum) {
                invalidDefinition(definition.name, "first key index is outside required arguments");
            }

            switch (key_range.last) {
                .remaining => {},
                .index => |last| {
                    if (last < key_range.first) {
                        invalidDefinition(definition.name, "last key index precedes first key index");
                    }
                    if (last >= definition.arity.minimum) {
                        invalidDefinition(definition.name, "last key index is outside required arguments");
                    }
                    if ((last - key_range.first) % key_range.step != 0) {
                        invalidDefinition(definition.name, "last key index is not reachable by key step");
                    }
                },
            }
        },
    }
}

fn invalidDefinition(comptime name: []const u8, comptime reason: []const u8) noreturn {
    const label = if (name.len == 0) "<empty>" else name;
    @compileError("invalid command definition `" ++ label ++ "`: " ++ reason);
}
