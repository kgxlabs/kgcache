const std = @import("std");
const resp = @import("resp.zig");
pub const BgRewriteAof = @import("commander/bgrewriteaof.zig");
pub const BgSave = @import("commander/bgsave.zig");
pub const Commander = @import("commander/interface.zig");
pub const Command = @import("commander/command.zig");
pub const DBSize = @import("commander/dbsize.zig");
pub const Del = @import("commander/del.zig");
pub const Echo = @import("commander/echo.zig");
pub const Get = @import("commander/get.zig");
pub const Ping = @import("commander/ping.zig");
pub const Save = @import("commander/save.zig");
pub const Select = @import("commander/select.zig");
pub const Set = @import("commander/set.zig");
pub const Error = Commander.Error;

const CommandKind = enum {
    bgrewriteaof,
    bgsave,
    command,
    dbsize,
    del,
    echo,
    get,
    ping,
    select,
    save,
    set,

    fn parse(keyword: []const u8) Error!CommandKind {
        if (std.ascii.eqlIgnoreCase(keyword, "bgrewriteaof")) return .bgrewriteaof;
        if (std.ascii.eqlIgnoreCase(keyword, "bgsave")) return .bgsave;
        if (std.ascii.eqlIgnoreCase(keyword, "command")) return .command;
        if (std.ascii.eqlIgnoreCase(keyword, "dbsize")) return .dbsize;
        if (std.ascii.eqlIgnoreCase(keyword, "del")) return .del;
        if (std.ascii.eqlIgnoreCase(keyword, "echo")) return .echo;
        if (std.ascii.eqlIgnoreCase(keyword, "get")) return .get;
        if (std.ascii.eqlIgnoreCase(keyword, "ping")) return .ping;
        if (std.ascii.eqlIgnoreCase(keyword, "save")) return .save;
        if (std.ascii.eqlIgnoreCase(keyword, "select")) return .select;
        if (std.ascii.eqlIgnoreCase(keyword, "set")) return .set;

        return error.UnknownCommand;
    }
};

pub fn init(allocator: std.mem.Allocator, value: resp.RESPValue) Error!Commander {
    const command_kind = try parseKeyword(value);
    const arguments = try parseArguments(value);

    return switch (command_kind) {
        .bgrewriteaof => try create(BgRewriteAof, allocator, arguments),
        .bgsave => try create(BgSave, allocator, arguments),
        .command => try create(Command, allocator, arguments),
        .dbsize => try create(DBSize, allocator, arguments),
        .del => try create(Del, allocator, arguments),
        .echo => try create(Echo, allocator, arguments),
        .get => try create(Get, allocator, arguments),
        .ping => try create(Ping, allocator, arguments),
        .save => try create(Save, allocator, arguments),
        .select => try create(Select, allocator, arguments),
        .set => try create(Set, allocator, arguments),
    };
}

fn create(comptime T: type, allocator: std.mem.Allocator, arguments: []resp.RESPValue) Error!Commander {
    const implementation = try allocator.create(T);
    implementation.* = .{
        .allocator = allocator,
        .arguments = arguments,
    };
    return implementation.commander();
}

// if it is not command input related error, propagate it
pub fn initErrorResponse(err: Error) ?[]const u8 {
    return switch (err) {
        error.UnknownCommand => "-ERR unknown command\r\n",
        error.UnsupportedKeyword => "-ERR unsupported command keyword\r\n",
        error.UnsupportedArgumentType => "-ERR unsupported argument type\r\n",
        error.MalformedCommandRequest => "-ERR malformed command request\r\n",
        error.OutOfMemory,
        error.WrongNumberArguments,
        error.UnableToConvertObject,
        error.UnsupportedOption,
        error.Syntax,
        error.SomethingWentWrong,
        error.AofDisabled,
        => null,
    };
}

pub fn executeErrorResponse(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.UnknownCommand => "-ERR unknown command\r\n",
        error.UnsupportedKeyword => "-ERR unsupported command keyword\r\n",
        error.UnsupportedArgumentType => "-ERR unsupported argument type\r\n",
        error.MalformedCommandRequest => "-ERR malformed command request\r\n",
        error.WrongNumberArguments => "-ERR wrong number of arguments\r\n",
        error.UnsupportedOption => "-ERR unsupported option\r\n",
        error.Syntax => "-ERR syntax error\r\n",
        error.SaveAlreadyInProgress => "-ERR save already in progress\r\n",
        error.AofDisabled => "-ERR AOF is disabled\r\n",
        error.OutOfMemory,
        error.UnableToConvertObject,
        error.SomethingWentWrong,
        => null,
        else => null,
    };
}

fn parseKeyword(value: resp.RESPValue) Error!CommandKind {
    return switch (value) {
        .array => |maybe_commands| {
            const commands = maybe_commands orelse return error.UnknownCommand;
            if (commands.len == 0) return error.MalformedCommandRequest;

            return switch (commands[0]) {
                .bulk_string => |maybe_keyword| CommandKind.parse(maybe_keyword orelse return error.UnknownCommand),
                else => error.UnsupportedKeyword,
            };
        },
        else => error.UnknownCommand,
    };
}

fn parseArguments(value: resp.RESPValue) Error![]resp.RESPValue {
    return switch (value) {
        .array => |maybe_request| {
            const request = maybe_request orelse return error.UnknownCommand;
            if (request.len == 0) return error.MalformedCommandRequest;

            const arguments = request[1..];
            for (arguments) |argument| {
                if (argument == .array) return error.UnsupportedArgumentType;
            }
            return arguments;
        },
        else => error.UnknownCommand,
    };
}

test "reject unknown command" {
    const testing = std.testing;
    var values = [_]resp.RESPValue{.{ .bulk_string = "UNKNOWN" }};
    try testing.expectError(error.UnknownCommand, init(testing.allocator, .{ .array = &values }));
}

test "reject empty command array" {
    const testing = std.testing;
    var values = [_]resp.RESPValue{};
    try testing.expectError(error.MalformedCommandRequest, init(testing.allocator, .{ .array = &values }));
}
