const std = @import("std");
const resp = @import("resp.zig");
const store = @import("store.zig");
const object = @import("object.zig");
const testing = std.testing;

const CommandKind = enum {
    command,
    echo,
    get,
    ping,
    set,

    pub fn parse(keyword: []const u8) CommanderError!CommandKind {
        if (std.ascii.eqlIgnoreCase(keyword, "command")) return .command;
        if (std.ascii.eqlIgnoreCase(keyword, "echo")) return .echo;
        if (std.ascii.eqlIgnoreCase(keyword, "get")) return .get;
        if (std.ascii.eqlIgnoreCase(keyword, "ping")) return .ping;
        if (std.ascii.eqlIgnoreCase(keyword, "set")) return .set;

        return error.UnknownCommand;
    }
};

const CommanderError = error{
    UnknownCommand,
    UnsupportedKeyword,
    UnsupportedArgumentType,
    MalformedCommandRequest,
    WrongNumberArguments,
    UnableToConvertObject,
};

const Commander = union(enum) {
    _command: CommandCommander,
    _echo: EchoCommander,
    _get: GetCommander,
    _ping: PingCommander,
    _set: SetCommander,

    pub fn execute(self: Commander, data_store: *store.Store) CommanderError!resp.RESPValue {
        return switch (self) {
            ._command => |c| return c.execute(data_store),
            ._echo => |c| return c.execute(data_store),
            ._get => |c| return c.execute(data_store),
            ._ping => |c| return c.execute(data_store),
            ._set => |c| return c.execute(data_store),
        };
    }
};

const GetCommander = struct {
    command: CommandKind,
    arguments: []resp.RESPValue,

    pub fn execute(self: GetCommander, data_store: *store.Store) CommanderError!resp.RESPValue {
        if (self.arguments.len == 0) {
            return .{
                // TODO: use error from error module after refactor
                .simple_error = "Wrong number of arguments",
            };
        }

        const key = try keyFromArg(self.arguments[0]);
        // TODO: Improve error message
        const obj_value = data_store.get(key) catch return resp.RESPValue{ .simple_error = "Unable to get" };

        const resp_value = object.toRESP(obj_value) catch return CommanderError.UnableToConvertObject;
        return resp_value;
    }
};

const SetCommander = struct {
    command: CommandKind,
    arguments: []resp.RESPValue,

    pub fn execute(_: SetCommander, _: *store.Store) CommanderError!resp.RESPValue {
        return resp.RESPValue{
            .simple_string = "OK",
        };
    }
};

const CommandCommander = struct {
    command: CommandKind,
    arguments: []resp.RESPValue,

    pub fn execute(self: CommandCommander, _: *store.Store) CommanderError!resp.RESPValue {
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

    pub fn execute(self: EchoCommander, _: *store.Store) CommanderError!resp.RESPValue {
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

    pub fn execute(_: PingCommander, _: *store.Store) CommanderError!resp.RESPValue {
        return .{
            .simple_string = "PONG",
        };
    }
};

pub fn init(value: resp.RESPValue) CommanderError!Commander {
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
        .ping => {
            return Commander{ ._ping = PingCommander{
                .command = command,
                .arguments = arguments,
            } };
        },
        .set => {
            return Commander{ ._set = SetCommander{
                .command = command,
                .arguments = arguments,
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
        error.UnableToConvertObject => .{ .simple_error = "ERR unable to conver object" },
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

fn keyFromArg(arg: resp.RESPValue) CommanderError![]const u8 {
    return switch (arg) {
        .bulk_string => |maybe_str| {
            const str = maybe_str orelse return CommanderError.MalformedCommandRequest;
            return str;
        },
        else => return CommanderError.UnsupportedArgumentType,
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
