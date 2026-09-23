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
const MockStore = @import("store/mock_store.zig");

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

fn executeWithMockStore(keyword: []const u8, arguments: []const resp.RESPValue, mock_store: *MockStore) anyerror!Commander.Result {
    var request: [3]resp.RESPValue = undefined;
    request[0] = .{ .bulk_string = keyword };
    for (arguments, 0..) |argument, index| request[index + 1] = argument;

    const command = try init(std.testing.allocator, .{ .array = request[0 .. arguments.len + 1] });
    defer command.deinit();

    var data_store = mock_store.store();
    var client_state: Commander.ClientState = .{};
    return command.execute(std.testing.io, &data_store, &client_state);
}

test "invalid arity returns before any store operation" {
    const testing = std.testing;
    const arguments = [_]resp.RESPValue{
        .{ .bulk_string = "key" },
        .{ .bulk_string = "extra" },
    };
    const cases = .{
        .{ "PING", 2 },
        .{ "GET", 0 },
        .{ "GET", 2 },
        .{ "SAVE", 1 },
        .{ "BGSAVE", 2 },
        .{ "BGREWRITEAOF", 1 },
    };

    inline for (cases) |case| {
        var mock_store = MockStore.init();
        try testing.expectError(error.WrongNumberArguments, executeWithMockStore(case[0], arguments[0..case[1]], &mock_store));
        try testing.expectEqual(@as(usize, 0), mock_store.get_calls);
        try testing.expectEqual(@as(usize, 0), mock_store.save_calls);
        try testing.expectEqual(@as(usize, 0), mock_store.bgsave_calls);
        try testing.expectEqual(@as(usize, 0), mock_store.bgrewriteaof_calls);
    }
}

test "ping returns PONG or the supplied message" {
    const testing = std.testing;
    var mock_store = MockStore.init();

    var empty_result = try executeWithMockStore("PING", &.{}, &mock_store);
    defer empty_result.deinit();
    try testing.expectEqualStrings("PONG", empty_result.value.simple_string);

    var message_result = try executeWithMockStore("PING", &.{.{ .bulk_string = "hello" }}, &mock_store);
    defer message_result.deinit();
    try testing.expectEqualStrings("hello", message_result.value.bulk_string.?);
}

test "valid arity delegates to the store" {
    const testing = std.testing;
    var mock_store = MockStore.init();

    var get_result = try executeWithMockStore("GET", &.{.{ .bulk_string = "key" }}, &mock_store);
    defer get_result.deinit();
    try testing.expect(get_result.value.bulk_string == null);
    try testing.expectEqual(@as(usize, 1), mock_store.get_calls);

    var save_result = try executeWithMockStore("SAVE", &.{}, &mock_store);
    defer save_result.deinit();
    try testing.expectEqualStrings("OK", save_result.value.simple_string);
    try testing.expectEqual(@as(usize, 1), mock_store.save_calls);

    var bgsave_result = try executeWithMockStore("BGSAVE", &.{}, &mock_store);
    defer bgsave_result.deinit();
    try testing.expectEqualStrings("Background saving started", bgsave_result.value.simple_string);

    mock_store.bgsave_result = .scheduled;
    var scheduled_result = try executeWithMockStore("BGSAVE", &.{.{ .bulk_string = "sChEdUlE" }}, &mock_store);
    defer scheduled_result.deinit();
    try testing.expectEqualStrings("Background saving scheduled", scheduled_result.value.simple_string);
    try testing.expectEqual(@as(usize, 2), mock_store.bgsave_calls);

    var rewrite_result = try executeWithMockStore("BGREWRITEAOF", &.{}, &mock_store);
    defer rewrite_result.deinit();
    try testing.expectEqualStrings("Background append only file rewriting started", rewrite_result.value.simple_string);
    try testing.expectEqual(@as(usize, 1), mock_store.bgrewriteaof_calls);
}

test "BGSAVE rejects an invalid option before calling the store" {
    const testing = std.testing;
    var mock_store = MockStore.init();

    try testing.expectError(
        error.Syntax,
        executeWithMockStore("BGSAVE", &.{.{ .bulk_string = "NOW" }}, &mock_store),
    );
    try testing.expectEqual(@as(usize, 0), mock_store.bgsave_calls);

    try testing.expectError(
        error.UnsupportedArgumentType,
        executeWithMockStore("BGSAVE", &.{.{ .integer = 1 }}, &mock_store),
    );
    try testing.expectEqual(@as(usize, 0), mock_store.bgsave_calls);
}

test "BGREWRITEAOF reports a scheduled rewrite" {
    const testing = std.testing;
    var mock_store = MockStore.init();
    mock_store.bgrewriteaof_result = .scheduled;

    var result = try executeWithMockStore("BGREWRITEAOF", &.{}, &mock_store);
    defer result.deinit();

    try testing.expectEqualStrings("Background append only file rewriting scheduled", result.value.simple_string);
    try testing.expectEqual(@as(usize, 1), mock_store.bgrewriteaof_calls);
}
