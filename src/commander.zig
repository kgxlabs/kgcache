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
    const request = try std.testing.allocator.alloc(resp.RESPValue, arguments.len + 1);
    defer std.testing.allocator.free(request);
    request[0] = .{ .bulk_string = keyword };
    for (arguments, 0..) |argument, index| request[index + 1] = argument;

    const command = try init(std.testing.allocator, .{ .array = request });
    defer command.deinit();

    var data_store = mock_store.store();
    var client_state: Commander.ClientState = .{};
    return command.execute(std.testing.io, &data_store, &client_state);
}

fn expectArray(value: resp.RESPValue) ![]resp.RESPValue {
    return switch (value) {
        .array => |items| items orelse error.TestUnexpectedResult,
        else => error.TestUnexpectedResult,
    };
}

fn expectBulk(value: resp.RESPValue, expected: []const u8) !void {
    switch (value) {
        .bulk_string => |text| try std.testing.expectEqualStrings(expected, text orelse return error.TestUnexpectedResult),
        else => return error.TestUnexpectedResult,
    }
}

fn expectBulkArray(value: resp.RESPValue, expected: []const []const u8) !void {
    const items = try expectArray(value);
    try std.testing.expectEqual(expected.len, items.len);
    for (items, expected) |item, text| try expectBulk(item, text);
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

test "COMMAND, COUNT, and LIST describe the available commands" {
    const testing = std.testing;
    var mock_store = MockStore.init();

    var all = try executeWithMockStore("COMMAND", &.{}, &mock_store);
    defer all.deinit();
    const details = try expectArray(all.value);

    var count = try executeWithMockStore("COMMAND", &.{.{ .bulk_string = "cOuNt" }}, &mock_store);
    defer count.deinit();
    try testing.expectEqual(@as(i64, @intCast(details.len)), count.value.integer);

    var info_all = try executeWithMockStore("COMMAND", &.{.{ .bulk_string = "INFO" }}, &mock_store);
    defer info_all.deinit();
    try testing.expectEqual(details.len, (try expectArray(info_all.value)).len);

    var list = try executeWithMockStore("COMMAND", &.{.{ .bulk_string = "LIST" }}, &mock_store);
    defer list.deinit();
    const names = try expectArray(list.value);
    try testing.expectEqual(details.len, names.len);

    var found_get = false;
    var found_command = false;
    for (details) |detail| {
        const fields = try expectArray(detail);
        try testing.expectEqual(@as(usize, 10), fields.len);
        if (std.mem.eql(u8, fields[0].bulk_string.?, "get")) found_get = true;
    }
    for (names) |name| {
        if (std.mem.eql(u8, name.bulk_string.?, "command")) found_command = true;
    }
    try testing.expect(found_get);
    try testing.expect(found_command);
}

test "COMMAND LIST filters names by pattern and ACL category" {
    const testing = std.testing;
    var mock_store = MockStore.init();

    var pattern = try executeWithMockStore("COMMAND", &.{
        .{ .bulk_string = "LIST" },    .{ .bulk_string = "FILTERBY" },
        .{ .bulk_string = "PATTERN" }, .{ .bulk_string = "g?t" },
    }, &mock_store);
    defer pattern.deinit();
    try expectBulkArray(pattern.value, &.{"get"});

    var prefix = try executeWithMockStore("COMMAND", &.{
        .{ .bulk_string = "LIST" },    .{ .bulk_string = "FILTERBY" },
        .{ .bulk_string = "PATTERN" }, .{ .bulk_string = "g*" },
    }, &mock_store);
    defer prefix.deinit();
    try expectBulkArray(prefix.value, &.{"get"});

    var no_match = try executeWithMockStore("COMMAND", &.{
        .{ .bulk_string = "LIST" },    .{ .bulk_string = "FILTERBY" },
        .{ .bulk_string = "PATTERN" }, .{ .bulk_string = "absent*" },
    }, &mock_store);
    defer no_match.deinit();
    try testing.expectEqual(@as(usize, 0), (try expectArray(no_match.value)).len);

    var category = try executeWithMockStore("COMMAND", &.{
        .{ .bulk_string = "LIST" },   .{ .bulk_string = "FILTERBY" },
        .{ .bulk_string = "ACLCAT" }, .{ .bulk_string = "@READ" },
    }, &mock_store);
    defer category.deinit();
    try expectBulkArray(category.value, &.{ "dbsize", "get" });
}

test "COMMAND INFO reports command metadata and unknown names" {
    const testing = std.testing;
    var mock_store = MockStore.init();

    var result = try executeWithMockStore("COMMAND", &.{
        .{ .bulk_string = "INFO" },    .{ .bulk_string = "gEt" },
        .{ .bulk_string = "missing" }, .{ .bulk_string = "DEL" },
    }, &mock_store);
    defer result.deinit();

    const commands = try expectArray(result.value);
    try testing.expectEqual(@as(usize, 3), commands.len);
    const get = try expectArray(commands[0]);
    try testing.expectEqual(@as(usize, 10), get.len);
    try expectBulk(get[0], "get");
    try testing.expectEqual(@as(i64, 2), get[1].integer);
    try expectBulkArray(get[2], &.{ "readonly", "fast" });
    try testing.expectEqual(@as(i64, 1), get[3].integer);
    try testing.expectEqual(@as(i64, 1), get[4].integer);
    try testing.expectEqual(@as(i64, 1), get[5].integer);
    try expectBulkArray(get[6], &.{ "@read", "@string", "@fast" });
    const specs = try expectArray(get[8]);
    try testing.expectEqual(@as(usize, 1), specs.len);
    const key_spec = try expectArray(specs[0]);
    try testing.expectEqual(@as(usize, 6), key_spec.len);
    try expectBulk(key_spec[0], "flags");
    try expectBulkArray(key_spec[1], &.{ "RO", "access" });
    try expectBulk(key_spec[2], "begin_search");
    try expectBulk(key_spec[4], "find_keys");
    try testing.expect(commands[1] == .array and commands[1].array == null);

    const del = try expectArray(commands[2]);
    try expectBulk(del[0], "del");
    try testing.expectEqual(@as(i64, -2), del[1].integer);
    try testing.expectEqual(@as(i64, -1), del[4].integer);

    const serializer = resp.serializer();
    const serialized = try serializer.serialize(testing.allocator, result.value);
    defer serializer.deinit(testing.allocator, serialized);
    try testing.expect(std.mem.indexOf(u8, serialized, "*-1\r\n") != null);
}

test "COMMAND GETKEYS extracts keys without changing them" {
    var mock_store = MockStore.init();

    var get = try executeWithMockStore("COMMAND", &.{
        .{ .bulk_string = "GETKEYS" }, .{ .bulk_string = "gEt" }, .{ .bulk_string = "one" },
    }, &mock_store);
    defer get.deinit();
    try expectBulkArray(get.value, &.{"one"});

    var set = try executeWithMockStore("COMMAND", &.{
        .{ .bulk_string = "GETKEYS" }, .{ .bulk_string = "SET" },
        .{ .bulk_string = "two" },     .{ .bulk_string = "value" },
        .{ .bulk_string = "GET" },
    }, &mock_store);
    defer set.deinit();
    try expectBulkArray(set.value, &.{"two"});

    var del = try executeWithMockStore("COMMAND", &.{
        .{ .bulk_string = "GETKEYS" }, .{ .bulk_string = "DEL" },
        .{ .bulk_string = "first" },   .{ .bulk_string = "second" },
        .{ .bulk_string = "third" },
    }, &mock_store);
    defer del.deinit();
    try expectBulkArray(del.value, &.{ "first", "second", "third" });
}

test "COMMAND GETKEYSANDFLAGS reports access for each key" {
    var mock_store = MockStore.init();

    var get = try executeWithMockStore("COMMAND", &.{
        .{ .bulk_string = "GETKEYSANDFLAGS" }, .{ .bulk_string = "GET" }, .{ .bulk_string = "one" },
    }, &mock_store);
    defer get.deinit();
    const get_keys = try expectArray(get.value);
    try std.testing.expectEqual(@as(usize, 1), get_keys.len);
    const get_pair = try expectArray(get_keys[0]);
    try std.testing.expectEqual(@as(usize, 2), get_pair.len);
    try expectBulk(get_pair[0], "one");
    try expectBulkArray(get_pair[1], &.{ "RO", "access" });

    var set = try executeWithMockStore("COMMAND", &.{
        .{ .bulk_string = "GETKEYSANDFLAGS" }, .{ .bulk_string = "SET" },
        .{ .bulk_string = "two" },             .{ .bulk_string = "value" },
    }, &mock_store);
    defer set.deinit();
    const set_pair = try expectArray((try expectArray(set.value))[0]);
    try expectBulkArray(set_pair[1], &.{ "OW", "update" });

    var set_get = try executeWithMockStore("COMMAND", &.{
        .{ .bulk_string = "GETKEYSANDFLAGS" }, .{ .bulk_string = "SET" },
        .{ .bulk_string = "two" },             .{ .bulk_string = "value" },
        .{ .bulk_string = "GET" },
    }, &mock_store);
    defer set_get.deinit();
    const set_get_pair = try expectArray((try expectArray(set_get.value))[0]);
    try expectBulkArray(set_get_pair[1], &.{ "RW", "access", "update" });

    var del = try executeWithMockStore("COMMAND", &.{
        .{ .bulk_string = "GETKEYSANDFLAGS" }, .{ .bulk_string = "DEL" },
        .{ .bulk_string = "first" },           .{ .bulk_string = "second" },
    }, &mock_store);
    defer del.deinit();
    const del_keys = try expectArray(del.value);
    try std.testing.expectEqual(@as(usize, 2), del_keys.len);
    for (del_keys, [_][]const u8{ "first", "second" }) |entry, key| {
        const pair = try expectArray(entry);
        try expectBulk(pair[0], key);
        try expectBulkArray(pair[1], &.{ "RM", "delete" });
    }
}

test "COMMAND rejects invalid forms" {
    const testing = std.testing;
    var mock_store = MockStore.init();

    try testing.expectError(
        error.UnsupportedOption,
        executeWithMockStore("COMMAND", &.{.{ .bulk_string = "UNKNOWN" }}, &mock_store),
    );
    try testing.expectError(
        error.UnsupportedArgumentType,
        executeWithMockStore("COMMAND", &.{.{ .integer = 1 }}, &mock_store),
    );
    try testing.expectError(error.WrongNumberArguments, executeWithMockStore("COMMAND", &.{
        .{ .bulk_string = "COUNT" }, .{ .bulk_string = "extra" },
    }, &mock_store));
    try testing.expectError(error.WrongNumberArguments, executeWithMockStore("COMMAND", &.{
        .{ .bulk_string = "LIST" }, .{ .bulk_string = "FILTERBY" },
    }, &mock_store));
    try testing.expectError(error.Syntax, executeWithMockStore("COMMAND", &.{
        .{ .bulk_string = "LIST" },   .{ .bulk_string = "FILTERBY" },
        .{ .bulk_string = "ACLCAT" }, .{ .bulk_string = "@missing" },
    }, &mock_store));
    try testing.expectError(error.UnsupportedOption, executeWithMockStore("COMMAND", &.{
        .{ .bulk_string = "LIST" },   .{ .bulk_string = "FILTERBY" },
        .{ .bulk_string = "MODULE" }, .{ .bulk_string = "module" },
    }, &mock_store));
    try testing.expectError(error.WrongNumberArguments, executeWithMockStore("COMMAND", &.{
        .{ .bulk_string = "GETKEYS" },
    }, &mock_store));
    try testing.expectError(error.UnknownCommand, executeWithMockStore("COMMAND", &.{
        .{ .bulk_string = "GETKEYS" }, .{ .bulk_string = "MISSING" },
    }, &mock_store));
    try testing.expectError(error.WrongNumberArguments, executeWithMockStore("COMMAND", &.{
        .{ .bulk_string = "GETKEYS" }, .{ .bulk_string = "GET" },
    }, &mock_store));
    try testing.expectError(error.Syntax, executeWithMockStore("COMMAND", &.{
        .{ .bulk_string = "GETKEYS" }, .{ .bulk_string = "PING" },
    }, &mock_store));
    try testing.expectError(error.UnsupportedArgumentType, executeWithMockStore("COMMAND", &.{
        .{ .bulk_string = "GETKEYS" }, .{ .bulk_string = "GET" }, .{ .integer = 1 },
    }, &mock_store));
    try testing.expectError(error.MalformedCommandRequest, executeWithMockStore("COMMAND", &.{
        .{ .bulk_string = "INFO" }, .{ .bulk_string = null },
    }, &mock_store));
}

test "supported command names keep their behavior" {
    const testing = std.testing;
    var mock_store = MockStore.init();

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
