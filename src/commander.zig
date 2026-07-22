const std = @import("std");
const resp = @import("resp.zig");

pub const Commander = @import("commander/interface.zig");
pub const Command = @import("commander/command.zig");
pub const Echo = @import("commander/echo.zig");
pub const Get = @import("commander/get.zig");
pub const Ping = @import("commander/ping.zig");
pub const Set = @import("commander/set.zig");
pub const Error = Commander.Error;

const CommandKind = enum {
    command,
    echo,
    get,
    ping,
    set,

    fn parse(keyword: []const u8) Error!CommandKind {
        if (std.ascii.eqlIgnoreCase(keyword, "command")) return .command;
        if (std.ascii.eqlIgnoreCase(keyword, "echo")) return .echo;
        if (std.ascii.eqlIgnoreCase(keyword, "get")) return .get;
        if (std.ascii.eqlIgnoreCase(keyword, "ping")) return .ping;
        if (std.ascii.eqlIgnoreCase(keyword, "set")) return .set;

        return error.UnknownCommand;
    }
};

pub fn init(allocator: std.mem.Allocator, value: resp.RESPValue) Error!Commander {
    const command_kind = try parseKeyword(value);
    const arguments = try parseArguments(value);

    return switch (command_kind) {
        .command => try create(Command, allocator, arguments),
        .echo => try create(Echo, allocator, arguments),
        .get => try create(Get, allocator, arguments),
        .ping => try create(Ping, allocator, arguments),
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

pub fn errorToRESPValue(err: Error) resp.RESPValue {
    return switch (err) {
        error.UnknownCommand => .{ .simple_error = "ERR unknown command" },
        error.UnsupportedKeyword => .{ .simple_error = "ERR unsupported command keyword" },
        error.UnsupportedArgumentType => .{ .simple_error = "ERR unsupported argument type" },
        error.MalformedCommandRequest => .{ .simple_error = "ERR malformed command request" },
        error.WrongNumberArguments => .{ .simple_error = "ERR wrong number of arguments" },
        error.UnableToConvertObject => .{ .simple_error = "ERR unable to conver object" },
        error.OutOfMemory => .{ .simple_error = "ERR out of memory" },
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
