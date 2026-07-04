const std = @import("std");
const resp = @import("../resp.zig");

const CommandKind = enum {
    command,
    echo,
    get,
    ping,

    pub fn parse(keyword: []const u8) ErrorCommander!CommandKind {
        if (std.ascii.eqlIgnoreCase(keyword, "command")) return .command;
        if (std.ascii.eqlIgnoreCase(keyword, "echo")) return .echo;
        if (std.ascii.eqlIgnoreCase(keyword, "get")) return .get;
        if (std.ascii.eqlIgnoreCase(keyword, "ping")) return .ping;

        return error.UnknownCommand;
    }
};

const ErrorCommander = error{
    UnknownCommand,
    UnsupportedKeyword,
    UnsupportedArgumentType,
    MalformedCommandRequest,
    WrongNumberArguments,
};

const GetCommander = struct {
    command: CommandKind,
    arguments: []resp.RESPValue,

    pub fn execute(self: CommandCommander) ErrorCommander!resp.RESPValue {
        return self.arguments[0];
    }
};

const CommandCommander = struct {
    command: CommandKind,
    arguments: []resp.RESPValue,

    pub fn execute(self: CommandCommander) ErrorCommander!resp.RESPValue {
        // TODO: Implement introspection
        return self.arguments[0];
    }
};

const EchoCommander = struct {
    command: CommandKind,
    arguments: []resp.RESPValue,

    pub fn execute(self: EchoCommander) ErrorCommander!resp.RESPValue {
        if (self.arguments.len != 1) {
            return ErrorCommander.MalformedCommandRequest;
        }

        const argument = self.arguments[0];

        switch (argument) {
            .bulk_string => |maybe_str| {
                if (maybe_str == null) {
                    return ErrorCommander.MalformedCommandRequest;
                }

                const str = maybe_str.?;
                return .{ .bulk_string = str };
            },
            else => {
                return ErrorCommander.UnsupportedArgumentType;
            },
        }
    }
};

const Commander = union(enum) {
    _command: CommandCommander,
    _echo: EchoCommander,
    _get: GetCommander,

    pub fn execute(self: Commander) ErrorCommander!resp.RESPValue {
        return switch (self) {
            ._command => |c| return c.execute(),
            ._echo => |c| return c.execute(),
            else => {
                return ErrorCommander.UnknownCommand;
            },
        };
    }
};

pub fn init(value: resp.RESPValue) ErrorCommander!Commander {
    const command = try parseKeyword(value);
    const arguments = try parseArguments(value);

    return switch (command) {
        .command => {
            return Commander{ ._command = CommandCommander{
                .command = command,
                .arguments = arguments,
            } };
        },
        .echo => {
            return Commander{ ._echo = EchoCommander{
                .command = command,
                .arguments = arguments,
            } };
        },
        else => {
            return ErrorCommander.UnknownCommand;
        },
    };
}

fn parseKeyword(value: resp.RESPValue) ErrorCommander!CommandKind {
    return switch (value) {
        .array => |maybe_commands| {
            if (maybe_commands == null) {
                return ErrorCommander.UnknownCommand;
            }

            const keyword = maybe_commands.?[0];

            return switch (keyword) {
                .bulk_string => |maybe_keyword| {
                    if (maybe_keyword == null) {
                        return ErrorCommander.UnknownCommand;
                    }
                    return try CommandKind.parse(maybe_keyword.?);
                },
                else => {
                    return ErrorCommander.UnsupportedKeyword;
                },
            };
        },
        else => {
            return ErrorCommander.UnknownCommand;
        },
    };
}

fn parseArguments(value: resp.RESPValue) ErrorCommander![]resp.RESPValue {
    return switch (value) {
        .array => |maybe_command_req| {
            if (maybe_command_req == null) {
                return ErrorCommander.UnknownCommand;
            }

            const command_req = maybe_command_req.?;

            if (command_req.len <= 0) {
                return ErrorCommander.MalformedCommandRequest;
            }

            const arguments = command_req[1..];

            for (arguments) |argument| {
                switch (argument) {
                    .array => {
                        return ErrorCommander.UnsupportedArgumentType;
                    },
                    else => {},
                }
            }

            return arguments;
        },
        else => {
            return ErrorCommander.UnknownCommand;
        },
    };
}
