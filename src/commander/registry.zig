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
    // Transitional until Redis-compatible COMMAND introspection replaces the placeholder.
    .{
        .name = "command",
        .arity = Arity.atLeast(1),
        .flags = &.{},
        .categories = &.{ .connection, .slow },
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
            },
        },
        .factory = factoryFor(Set),
    },
};

comptime {
    _ = definitions;
}
