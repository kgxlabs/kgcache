const std = @import("std");
const resp = @import("resp.zig");
const registry = @import("commander/registry.zig");
pub const Commander = @import("commander/interface.zig");
pub const Error = Commander.Error;

pub fn init(allocator: std.mem.Allocator, value: resp.RESPValue) Error!Commander {
    const keyword = try parseKeyword(value);
    const definition = registry.find(keyword) orelse return error.UnknownCommand;
    const arguments = try parseArguments(value);

    if (!definition.arity.accepts(arguments.len)) return error.WrongNumberArguments;

    return definition.factory(allocator, arguments);
}

fn parseKeyword(value: resp.RESPValue) Error![]const u8 {
    return switch (value) {
        .array => |maybe_commands| {
            const commands = maybe_commands orelse return error.UnknownCommand;
            if (commands.len == 0) return error.MalformedCommandRequest;

            return switch (commands[0]) {
                .bulk_string => |maybe_keyword| maybe_keyword orelse error.UnknownCommand,
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
