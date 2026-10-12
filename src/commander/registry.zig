const std = @import("std");
const BgRewriteAof = @import("bgrewriteaof.zig");
const BgSave = @import("bgsave.zig");
const ClientInfo = @import("client/client_info.zig");
const ClientSetinfo = @import("client/client_setinfo.zig");
const ClientList = @import("client/client_list.zig");
const Command = @import("command/command.zig");
const CommandCount = @import("command/command_count.zig");
const CommandList = @import("command/command_list.zig");
const CommandInfo = @import("command/command_info.zig");
const CommandGetkeys = @import("command/command_getkeys.zig");
const CommandGetkeysandflags = @import("command/command_getkeysandflags.zig");
const DBSize = @import("dbsize.zig");
const Del = @import("del.zig");
const Echo = @import("echo.zig");
const Get = @import("get.zig");
const Hello = @import("hello.zig");
const Commander = @import("interface.zig");
const CommandFrame = @import("../protocol/command_frame.zig");
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

pub fn resolve(frame: CommandFrame) Commander.Error!*const Definition {
    const definition = find(frame.name) orelse return error.UnknownCommand;
    return resolveDefinition(definition, frame.arguments);
}

fn resolveDefinition(definition: *const Definition, arguments: []const []const u8) Commander.Error!*const Definition {
    if (!definition.arity.accepts(arguments.len)) return error.WrongNumberArguments;

    switch (definition.kind) {
        .command => return definition,
        .namespace => {},
        .group => if (arguments.len == 0) return definition,
    }

    if (arguments.len == 0) return error.WrongNumberArguments;

    for (definition.subcommands) |*subcommand| {
        const selector = subcommand.name[definition.name.len + 1 ..];
        if (!std.ascii.eqlIgnoreCase(arguments[0], selector)) continue;
        if (!subcommand.arity.accepts(arguments.len)) return error.WrongNumberArguments;
        return subcommand;
    }

    return error.UnsupportedOption;
}

pub fn all() []const Definition {
    return definitions[0..];
}

pub fn findMetadata(name: []const u8) ?*const Definition {
    if (find(name)) |definition| return definition;
    for (definitions) |definition| {
        for (definition.subcommands) |*subcommand| {
            if (std.ascii.eqlIgnoreCase(name, subcommand.name)) return subcommand;
        }
    }
    return null;
}

fn factoryFor(comptime T: type) Factory {
    return struct {
        fn create(allocator: std.mem.Allocator, arguments: []const []const u8) Commander.Error!Commander {
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
        .kind = .command,
        .arity = Arity.exact(0),
        .flags = &.{.admin},
        .categories = &.{ .admin, .slow, .dangerous },
        .keys = .none,
        .factory = factoryFor(BgRewriteAof),
    },
    .{
        .name = "bgsave",
        .kind = .command,
        .arity = Arity.range(0, 1),
        .flags = &.{.admin},
        .categories = &.{ .admin, .slow, .dangerous },
        .keys = .none,
        .factory = factoryFor(BgSave),
    },
    .{
        .name = "client",
        .kind = .namespace,
        .arity = Arity.atLeast(1),
        .flags = &.{},
        .categories = &.{ .connection, .slow },
        .keys = .none,
        .factory = null,
        .subcommands = &.{
            .{
                .name = "client|info",
                .kind = .command,
                .arity = Arity.exact(1),
                .flags = &.{.fast},
                .categories = &.{ .connection, .fast },
                .keys = .none,
                .factory = ClientInfo.init,
            },
            .{
                .name = "client|setinfo",
                .kind = .command,
                .arity = Arity.exact(3),
                .flags = &.{},
                .categories = &.{ .connection, .slow },
                .keys = .none,
                .factory = ClientSetinfo.init,
            },
            .{
                .name = "client|list",
                .kind = .command,
                .arity = Arity.exact(1),
                .flags = &.{.admin},
                .categories = &.{ .admin, .connection, .slow, .dangerous },
                .keys = .none,
                .factory = ClientList.init,
            },
        },
    },
    .{
        .name = "command",
        .kind = .group,
        .arity = Arity.atLeast(0),
        .flags = &.{.fast},
        .categories = &.{ .connection, .fast },
        .keys = .none,
        .factory = Command.init,
        .subcommands = &.{
            .{
                .name = "command|count",
                .kind = .command,
                .arity = Arity.exact(1),
                .flags = &.{.fast},
                .categories = &.{ .connection, .fast },
                .keys = .none,
                .factory = CommandCount.init,
            },
            .{
                .name = "command|list",
                .kind = .command,
                .arity = Arity.atLeast(1),
                .flags = &.{.fast},
                .categories = &.{ .connection, .fast },
                .keys = .none,
                .factory = CommandList.init,
            },
            .{
                .name = "command|info",
                .kind = .command,
                .arity = Arity.atLeast(1),
                .flags = &.{.fast},
                .categories = &.{ .connection, .fast },
                .keys = .none,
                .factory = CommandInfo.init,
            },
            .{
                .name = "command|getkeys",
                .kind = .command,
                .arity = Arity.atLeast(2),
                .flags = &.{.fast},
                .categories = &.{ .connection, .fast },
                .keys = .none,
                .factory = CommandGetkeys.init,
            },
            .{
                .name = "command|getkeysandflags",
                .kind = .command,
                .arity = Arity.atLeast(2),
                .flags = &.{.fast},
                .categories = &.{ .connection, .fast },
                .keys = .none,
                .factory = CommandGetkeysandflags.init,
            },
        },
    },
    .{
        .name = "dbsize",
        .kind = .command,
        .arity = Arity.exact(0),
        .flags = &.{ .readonly, .fast },
        .categories = &.{ .keyspace, .read, .fast },
        .keys = .none,
        .factory = factoryFor(DBSize),
    },
    .{
        .name = "del",
        .kind = .command,
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
        .kind = .command,
        .arity = Arity.exact(1),
        .flags = &.{.fast},
        .categories = &.{ .connection, .fast },
        .keys = .none,
        .factory = factoryFor(Echo),
    },
    .{
        .name = "get",
        .kind = .command,
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
        .name = "hello",
        .kind = .command,
        .arity = Arity.atLeast(0),
        .flags = &.{.fast},
        .categories = &.{ .connection, .fast },
        .keys = .none,
        .factory = factoryFor(Hello),
    },
    .{
        .name = "ping",
        .kind = .command,
        .arity = Arity.range(0, 1),
        .flags = &.{.fast},
        .categories = &.{ .connection, .fast },
        .keys = .none,
        .factory = factoryFor(Ping),
    },
    .{
        .name = "save",
        .kind = .command,
        .arity = Arity.exact(0),
        .flags = &.{.admin},
        .categories = &.{ .admin, .slow, .dangerous },
        .keys = .none,
        .factory = factoryFor(Save),
    },
    .{
        .name = "select",
        .kind = .command,
        .arity = Arity.exact(1),
        .flags = &.{.fast},
        .categories = &.{ .connection, .fast },
        .keys = .none,
        .factory = factoryFor(Select),
    },
    .{
        .name = "set",
        .kind = .command,
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
    validateDefinitions(&definitions);
}

fn validateDefinitions(comptime entries: []const Definition) void {
    inline for (entries, 0..) |definition, index| {
        validateName(definition);
        validateArity(definition);
        validateKind(definition, false);
        validateKeys(definition, false);
        inline for (definition.subcommands, 0..) |subcommand, sub_index| {
            const prefix = definition.name ++ "|";
            if (!std.mem.startsWith(u8, subcommand.name, prefix)) invalidDefinition(subcommand.name, "must include its parent command name");
            var leaf = subcommand;
            leaf.name = subcommand.name[prefix.len..];
            validateName(leaf);
            validateArity(subcommand);
            validateKind(subcommand, true);
            validateKeys(subcommand, true);
            if (subcommand.subcommands.len != 0) invalidDefinition(subcommand.name, "nested subcommands are unsupported");
            inline for (definition.subcommands, 0..) |other, other_index| {
                if (other_index > sub_index and std.ascii.eqlIgnoreCase(subcommand.name, other.name)) {
                    invalidDefinition(subcommand.name, "duplicates a subcommand");
                }
            }
        }

        inline for (entries, 0..) |other, other_index| {
            if (other_index > index and std.ascii.eqlIgnoreCase(definition.name, other.name)) {
                invalidDefinition(definition.name, "duplicates command `" ++ other.name ++ "`");
            }
        }
    }
}

fn validateKind(comptime definition: Definition, comptime is_child: bool) void {
    switch (definition.kind) {
        .command => {
            if (definition.factory == null) invalidDefinition(definition.name, "command must have a factory");
            if (definition.subcommands.len != 0) invalidDefinition(definition.name, "command must not have children");
        },
        .namespace => {
            if (definition.factory != null) invalidDefinition(definition.name, "namespace must not have a factory");
            if (definition.subcommands.len == 0) invalidDefinition(definition.name, "namespace must have children");
            if (definition.arity.minimum == 0) invalidDefinition(definition.name, "namespace must require a child argument");
        },
        .group => {
            if (definition.factory == null) invalidDefinition(definition.name, "group must have a factory");
            if (definition.subcommands.len == 0) invalidDefinition(definition.name, "group must have children");
            if (!definition.arity.accepts(0)) invalidDefinition(definition.name, "group must accept zero arguments");
        },
    }

    if (is_child and definition.arity.minimum == 0) {
        invalidDefinition(definition.name, "child must include its selector in the argument count");
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

fn validateKeys(comptime definition: Definition, comptime is_child: bool) void {
    switch (definition.keys) {
        .none => {},
        .range => |key_range| {
            if (key_range.step == 0) invalidDefinition(definition.name, "key step must be greater than zero");

            if (key_range.flags.len == 0) invalidDefinition(definition.name, "key flags must not be empty");

            if (key_range.first >= definition.arity.minimum) {
                invalidDefinition(definition.name, "first key index is outside required arguments");
            }

            if (is_child and key_range.first == 0) {
                invalidDefinition(definition.name, "child key range must not include the selector at index zero");
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

test "registry selects namespace children and checks counts before creating handlers" {
    const testing = std.testing;
    const client = find("client").?;
    try testing.expect(client.factory == null);

    const cases = .{
        .{ &.{"iNfO"}, "client|info" },
        .{ &.{"lIsT"}, "client|list" },
        .{ &.{ "sEtInFo", "LIB-NAME", "value" }, "client|setinfo" },
    };
    inline for (cases) |case| {
        const selected = try resolve(.{ .name = "cLiEnT", .arguments = case[0] });
        try testing.expect(selected == findMetadata(case[1]).?);
        try testing.expect(selected.factory != null);
    }

    try testing.expectError(error.WrongNumberArguments, resolve(.{ .name = "CLIENT", .arguments = &.{} }));
    try testing.expectError(error.WrongNumberArguments, resolve(.{ .name = "CLIENT", .arguments = &.{ "INFO", "extra" } }));
    try testing.expectError(error.WrongNumberArguments, resolve(.{ .name = "CLIENT", .arguments = &.{ "SETINFO", "LIB-NAME" } }));
    try testing.expectError(error.UnsupportedOption, resolve(.{ .name = "CLIENT", .arguments = &.{"UNKNOWN"} }));
    try testing.expectError(error.UnknownCommand, resolve(.{ .name = "client|info", .arguments = &.{} }));
    try testing.expectError(error.UnknownCommand, resolve(.{ .name = "UNKNOWN", .arguments = &.{} }));
    try testing.expect(try resolve(.{ .name = "GET", .arguments = &.{"INFO"} }) == find("get").?);
}

test "registry groups select their bare handler or a registered child" {
    const testing = std.testing;
    const group = comptime Definition{
        .name = "sample",
        .kind = .group,
        .arity = Arity.atLeast(0),
        .flags = &.{},
        .categories = &.{},
        .keys = .none,
        .factory = factoryFor(Ping),
        .subcommands = &.{.{
            .name = "sample|child",
            .kind = .command,
            .arity = Arity.exact(1),
            .flags = &.{},
            .categories = &.{},
            .keys = .none,
            .factory = factoryFor(Ping),
        }},
    };
    comptime validateDefinitions(&.{group});

    try testing.expect(try resolveDefinition(&group, &.{}) == &group);
    try testing.expect(try resolveDefinition(&group, &.{"cHiLd"}) == &group.subcommands[0]);
    try testing.expectError(error.UnsupportedOption, resolveDefinition(&group, &.{"UNKNOWN"}));
    try testing.expectError(error.WrongNumberArguments, resolveDefinition(&group, &.{ "CHILD", "extra" }));
}
