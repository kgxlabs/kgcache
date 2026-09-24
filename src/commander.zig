const std = @import("std");
const resp = @import("resp.zig");
const registry = @import("commander/registry.zig");
pub const Commander = @import("commander/interface.zig");
pub const Error = Commander.Error;
const MockStore = @import("store/mock_store.zig");

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

test "reject unsupported command input shapes" {
    const testing = std.testing;

    var non_bulk_keyword = [_]resp.RESPValue{.{ .integer = 1 }};
    try testing.expectError(
        error.UnsupportedKeyword,
        init(testing.allocator, .{ .array = &non_bulk_keyword }),
    );

    var nested_argument = [_]resp.RESPValue{
        .{ .bulk_string = "GET" },
        .{ .array = null },
    };
    try testing.expectError(
        error.UnsupportedArgumentType,
        init(testing.allocator, .{ .array = &nested_argument }),
    );
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

test "commands reject invalid argument counts" {
    const testing = std.testing;
    const arguments = [_]resp.RESPValue{
        .{ .bulk_string = "key" },
        .{ .bulk_string = "extra" },
    };
    const cases = .{
        .{ "BGREWRITEAOF", 1 },
        .{ "BGSAVE", 2 },
        .{ "COMMAND", 0 },
        .{ "DBSIZE", 1 },
        .{ "DEL", 0 },
        .{ "ECHO", 0 },
        .{ "ECHO", 2 },
        .{ "GET", 0 },
        .{ "GET", 2 },
        .{ "PING", 2 },
        .{ "SAVE", 1 },
        .{ "SELECT", 0 },
        .{ "SELECT", 2 },
        .{ "SET", 1 },
    };

    inline for (cases) |case| {
        var mock_store = MockStore.init();
        try testing.expectError(error.WrongNumberArguments, executeWithMockStore(case[0], arguments[0..case[1]], &mock_store));
    }
}

test "invalid argument counts do not start persistence" {
    const testing = std.testing;
    const arguments = [_]resp.RESPValue{
        .{ .bulk_string = "one" },
        .{ .bulk_string = "two" },
    };
    const cases = .{
        .{ "BGREWRITEAOF", 1 },
        .{ "BGSAVE", 2 },
        .{ "SAVE", 1 },
    };

    inline for (cases) |case| {
        var mock_store = MockStore.init();
        try testing.expectError(error.WrongNumberArguments, executeWithMockStore(case[0], arguments[0..case[1]], &mock_store));
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

test "command names are case-insensitive" {
    const testing = std.testing;
    var mock_store = MockStore.init();

    var result = try executeWithMockStore("pInG", &.{}, &mock_store);
    defer result.deinit();

    try testing.expectEqualStrings("PONG", result.value.simple_string);
}

test "supported command names keep their behavior" {
    const testing = std.testing;
    var mock_store = MockStore.init();

    var command_result = try executeWithMockStore("COMMAND", &.{.{ .bulk_string = "INFO" }}, &mock_store);
    defer command_result.deinit();
    try testing.expectEqualStrings("INFO", command_result.value.bulk_string.?);

    mock_store.dbsize_result = 42;
    var dbsize_result = try executeWithMockStore("DBSIZE", &.{}, &mock_store);
    defer dbsize_result.deinit();
    try testing.expectEqual(@as(i64, 42), dbsize_result.value.integer);

    var del_result = try executeWithMockStore("DEL", &.{.{ .bulk_string = "key" }}, &mock_store);
    defer del_result.deinit();
    try testing.expectEqual(@as(i64, 0), del_result.value.integer);

    var echo_result = try executeWithMockStore("ECHO", &.{.{ .bulk_string = "hello" }}, &mock_store);
    defer echo_result.deinit();
    try testing.expectEqualStrings("hello", echo_result.value.bulk_string.?);

    var get_result = try executeWithMockStore("GET", &.{.{ .bulk_string = "key" }}, &mock_store);
    defer get_result.deinit();
    try testing.expect(get_result.value.bulk_string == null);

    var save_result = try executeWithMockStore("SAVE", &.{}, &mock_store);
    defer save_result.deinit();
    try testing.expectEqualStrings("OK", save_result.value.simple_string);

    var bgsave_result = try executeWithMockStore("BGSAVE", &.{}, &mock_store);
    defer bgsave_result.deinit();
    try testing.expectEqualStrings("Background saving started", bgsave_result.value.simple_string);

    mock_store.bgsave_result = .scheduled;
    var scheduled_bgsave_result = try executeWithMockStore("BGSAVE", &.{.{ .bulk_string = "sChEdUlE" }}, &mock_store);
    defer scheduled_bgsave_result.deinit();
    try testing.expectEqualStrings("Background saving scheduled", scheduled_bgsave_result.value.simple_string);

    var rewrite_result = try executeWithMockStore("BGREWRITEAOF", &.{}, &mock_store);
    defer rewrite_result.deinit();
    try testing.expectEqualStrings("Background append only file rewriting started", rewrite_result.value.simple_string);

    var select_result = try executeWithMockStore("SELECT", &.{.{ .bulk_string = "0" }}, &mock_store);
    defer select_result.deinit();
    try testing.expectEqualStrings("OK", select_result.value.simple_string);

    var set_result = try executeWithMockStore(
        "SET",
        &.{ .{ .bulk_string = "key" }, .{ .bulk_string = "value" } },
        &mock_store,
    );
    defer set_result.deinit();
    try testing.expectEqualStrings("OK", set_result.value.simple_string);
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
}
