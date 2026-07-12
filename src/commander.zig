const std = @import("std");
const resp = @import("resp.zig");
const store = @import("store.zig");
const testing = std.testing;

const CommandKind = enum {
    command,
    echo,
    get,
    ping,

    pub fn parse(keyword: []const u8) CommanderError!CommandKind {
        if (std.ascii.eqlIgnoreCase(keyword, "command")) return .command;
        if (std.ascii.eqlIgnoreCase(keyword, "echo")) return .echo;
        if (std.ascii.eqlIgnoreCase(keyword, "get")) return .get;
        if (std.ascii.eqlIgnoreCase(keyword, "ping")) return .ping;

        return error.UnknownCommand;
    }
};

const CommanderError = error{
    UnknownCommand,
    UnsupportedKeyword,
    UnsupportedArgumentType,
    MalformedCommandRequest,
    WrongNumberArguments,
};

const GetCommander = struct {
    command: CommandKind,
    arguments: []resp.RESPValue,
    data_store: *store.Store,

    pub fn execute(self: GetCommander) CommanderError!resp.RESPValue {
        if (self.arguments.len == 0) {
            return .{
                // TODO: use error from error module after refactor
                .simple_error = "Wrong number of arguments",
            };
        }
        // TODO: Implement
        return self.arguments[0];
    }
};

const CommandCommander = struct {
    command: CommandKind,
    arguments: []resp.RESPValue,
    data_store: *store.Store,

    pub fn execute(self: CommandCommander) CommanderError!resp.RESPValue {
        if (self.arguments.len == 0) {
            return .{
                // TODO: use error from error module after refactor
                .simple_error = "Wrong number of arguments",
            };
        }
        // TODO: Implement introspection
        return self.arguments[0];
    }
};

const EchoCommander = struct {
    command: CommandKind,
    arguments: []resp.RESPValue,
    data_store: *store.Store,

    pub fn execute(self: EchoCommander) CommanderError!resp.RESPValue {
        if (self.arguments.len != 1) {
            return .{
                // TODO: use error from error module after refactor
                .simple_error = "Wrong number of arguments",
            };
        }

        const argument = self.arguments[0];

        switch (argument) {
            .bulk_string => |maybe_str| {
                if (maybe_str == null) {
                    return CommanderError.MalformedCommandRequest;
                }

                const str = maybe_str.?;
                return .{ .bulk_string = str };
            },
            else => {
                return CommanderError.UnsupportedArgumentType;
            },
        }
    }
};

const PingCommander = struct {
    command: CommandKind,
    arguments: []resp.RESPValue,
    data_store: *store.Store,

    pub fn execute(_: PingCommander) CommanderError!resp.RESPValue {
        return .{
            .simple_string = "PONG",
        };
    }
};

const Commander = union(enum) {
    _command: CommandCommander,
    _echo: EchoCommander,
    _get: GetCommander,
    _ping: PingCommander,

    pub fn execute(self: Commander) CommanderError!resp.RESPValue {
        return switch (self) {
            ._command => |c| return c.execute(),
            ._echo => |c| return c.execute(),
            ._ping => |c| return c.execute(),
            else => {
                return CommanderError.UnknownCommand;
            },
        };
    }
};

pub fn init(data_store: *store.Store, value: resp.RESPValue) CommanderError!Commander {
    const command = try parseKeyword(value);
    const arguments = try parseArguments(value);

    return switch (command) {
        .command => {
            return Commander{ ._command = CommandCommander{
                .command = command,
                .arguments = arguments,
                .data_store = data_store,
            } };
        },
        .echo => {
            return Commander{ ._echo = EchoCommander{
                .command = command,
                .arguments = arguments,
                .data_store = data_store,
            } };
        },
        .ping => {
            return Commander{ ._ping = PingCommander{
                .command = command,
                .arguments = arguments,
                .data_store = data_store,
            } };
        },
        else => {
            return CommanderError.UnknownCommand;
        },
    };
}

pub fn errorToRESPValue(err: CommanderError) resp.RESPValue {
    return switch (err) {
        error.UnknownCommand => .{ .simple_error = "ERR unknown command" },
        error.UnsupportedKeyword => .{ .simple_error = "ERR unsupported command keyword" },
        error.UnsupportedArgumentType => .{ .simple_error = "ERR unsupported argument type" },
        error.MalformedCommandRequest => .{ .simple_error = "ERR malformed command request" },
        error.WrongNumberArguments => .{ .simple_error = "ERR wrong number of arguments" },
    };
}

fn parseKeyword(value: resp.RESPValue) CommanderError!CommandKind {
    return switch (value) {
        .array => |maybe_commands| {
            const commands = maybe_commands orelse return CommanderError.UnknownCommand;

            if (commands.len == 0) {
                return CommanderError.MalformedCommandRequest;
            }

            const keyword = commands[0];

            return switch (keyword) {
                .bulk_string => |maybe_keyword| {
                    if (maybe_keyword == null) {
                        return CommanderError.UnknownCommand;
                    }
                    return try CommandKind.parse(maybe_keyword.?);
                },
                else => {
                    return CommanderError.UnsupportedKeyword;
                },
            };
        },
        else => {
            return CommanderError.UnknownCommand;
        },
    };
}

fn parseArguments(value: resp.RESPValue) CommanderError![]resp.RESPValue {
    return switch (value) {
        .array => |maybe_command_req| {
            if (maybe_command_req == null) {
                return CommanderError.UnknownCommand;
            }

            const command_req = maybe_command_req.?;

            if (command_req.len <= 0) {
                return CommanderError.MalformedCommandRequest;
            }

            const arguments = command_req[1..];

            for (arguments) |argument| {
                switch (argument) {
                    .array => {
                        return CommanderError.UnsupportedArgumentType;
                    },
                    else => {},
                }
            }

            return arguments;
        },
        else => {
            return CommanderError.UnknownCommand;
        },
    };
}

test "execute ping command" {
    var values = [_]resp.RESPValue{
        .{ .bulk_string = "PING" },
    };

    const c = try init(.{ .array = &values });
    const result = try c.execute();

    try expectSimpleString(result, "PONG");
}

test "execute echo command" {
    var values = [_]resp.RESPValue{
        .{ .bulk_string = "ECHO" },
        .{ .bulk_string = "hello" },
    };

    const c = try init(.{ .array = &values });
    const result = try c.execute();

    try expectBulkString(result, "hello");
}

test "reject unknown command" {
    var values = [_]resp.RESPValue{
        .{ .bulk_string = "UNKNOWN" },
    };

    try testing.expectError(CommanderError.UnknownCommand, init(.{ .array = &values }));
}

test "reject empty command array" {
    var values = [_]resp.RESPValue{};

    try testing.expectError(CommanderError.MalformedCommandRequest, init(.{ .array = &values }));
}

test "reject unsupported argument type" {
    var values = [_]resp.RESPValue{
        .{ .bulk_string = "ECHO" },
        .{ .integer = 1 },
    };

    const c = try init(.{ .array = &values });

    try testing.expectError(CommanderError.UnsupportedArgumentType, c.execute());
}

fn expectBulkString(value: resp.RESPValue, expected: []const u8) !void {
    switch (value) {
        .bulk_string => |maybe_value| {
            const actual = maybe_value orelse return error.TestUnexpectedResult;
            try testing.expectEqualStrings(expected, actual);
        },
        else => return error.TestUnexpectedResult,
    }
}

fn expectSimpleString(value: resp.RESPValue, expected: []const u8) !void {
    switch (value) {
        .simple_string => |actual| try testing.expectEqualStrings(expected, actual),
        else => return error.TestUnexpectedResult,
    }
}
