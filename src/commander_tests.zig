const std = @import("std");
const protocol = @import("protocol.zig");
const Reply = protocol.Reply;
const commander = @import("commander.zig");
const Commander = commander.Commander;
const store = @import("store.zig");
const MockStore = @import("store/mock_store.zig");
const init = commander.init;

test "reject unknown command" {
    for ([_][]const u8{ "UNKNOWN", "" }) |name| {
        try std.testing.expectError(error.UnknownCommand, init(std.testing.allocator, .{ .name = name, .arguments = &.{} }));
    }
}

fn executeWithMockStore(keyword: []const u8, arguments: []const []const u8, mock_store: *MockStore) anyerror!Commander.Result {
    var data_store = mock_store.store();
    var client_state: Commander.ClientState = .{};
    return executeWithStore(keyword, arguments, &data_store, &client_state);
}

fn executeWithStore(keyword: []const u8, arguments: []const []const u8, data_store: *store.Store, client_state: *Commander.ClientState) anyerror!Commander.Result {
    return executeWithAllocator(std.testing.allocator, keyword, arguments, data_store, client_state);
}

fn executeWithAllocator(allocator: std.mem.Allocator, keyword: []const u8, arguments: []const []const u8, data_store: *store.Store, client_state: *Commander.ClientState) anyerror!Commander.Result {
    const command = try init(allocator, .{ .name = keyword, .arguments = arguments });
    defer command.deinit();
    return command.execute(std.testing.io, data_store, client_state);
}

test "GET and SET GET replies survive replacement and output failures without leaking" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, replyLifetime, .{});
}

fn replyLifetime(allocator: std.mem.Allocator) !void {
    const testing = std.testing;
    const DefaultStorage = @import("storage/default_storage.zig");
    const PersistenceState = @import("persistence_state.zig");
    const persistence = @import("persistence.zig");
    var backend = DefaultStorage.init(testing.io, allocator);
    var persistence_state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });
    var kgc = try persistence.KgcPersistence.init(testing.io, allocator, &persistence_state, "reply-lifetime.kgc");
    var memory_store = store.MemoryStore.init(allocator, &.{backend.storage()}, kgc.snapshot(), null);
    var data_store = memory_store.store();
    defer data_store.deinit();
    var state = Commander.ClientState.init();

    var initial = try executeWithAllocator(allocator, "SET", &.{ "key", "\x00\r\n" }, &data_store, &state);
    defer initial.deinit();
    var get = try executeWithAllocator(allocator, "GET", &.{"key"}, &data_store, &state);
    defer get.deinit();
    var previous = try executeWithAllocator(allocator, "SET", &.{ "key", "second", "GET" }, &data_store, &state);
    defer previous.deinit();
    var replacement = try executeWithAllocator(allocator, "SET", &.{ "key", "third" }, &data_store, &state);
    defer replacement.deinit();

    for ([_]protocol.Resp{ protocol.Resp2.resp(), protocol.Resp3.resp() }) |selected| {
        for ([_]Reply{ get.value, previous.value }) |reply| {
            var small_buffer: [1]u8 = undefined;
            var failing_writer = std.Io.Writer.fixed(&small_buffer);
            try testing.expectError(error.WriteFailed, selected.writeReply(&failing_writer, reply));
            var buffer: [32]u8 = undefined;
            var writer = std.Io.Writer.fixed(&buffer);
            try selected.writeReply(&writer, reply);
            try writer.flush();
            try testing.expectEqualStrings("$3\r\n\x00\r\n\r\n", writer.buffered());
        }
    }
}

fn expectArray(value: Reply) ![]const Reply {
    return switch (value) {
        .array => |items| items,
        else => error.TestUnexpectedResult,
    };
}

fn expectBulk(value: Reply, expected: []const u8) !void {
    switch (value) {
        .blob_string => |text| try std.testing.expectEqualStrings(expected, text),
        else => return error.TestUnexpectedResult,
    }
}

fn expectBulkArray(value: Reply, expected: []const []const u8) !void {
    const items = try expectArray(value);
    try std.testing.expectEqual(expected.len, items.len);
    for (items, expected) |item, text| try expectBulk(item, text);
}

test "commands reject invalid argument counts" {
    const testing = std.testing;
    const arguments = [_][]const u8{
        "key",
        "extra",
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
        .{ "SET", 0 },
        .{ "SET", 1 },
    };

    inline for (cases) |case| {
        var mock_store = MockStore.init();
        try testing.expectError(error.WrongNumberArguments, executeWithMockStore(case[0], arguments[0..case[1]], &mock_store));
    }
}

test "invalid argument counts do not start persistence" {
    const testing = std.testing;
    const arguments = [_][]const u8{
        "one",
        "two",
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

    var message_result = try executeWithMockStore("PING", &.{"hello"}, &mock_store);
    defer message_result.deinit();
    try testing.expectEqualStrings("hello", message_result.value.blob_string);
}

test "command names are case-insensitive" {
    const testing = std.testing;
    var mock_store = MockStore.init();

    var result = try executeWithMockStore("pInG", &.{}, &mock_store);
    defer result.deinit();

    try testing.expectEqualStrings("PONG", result.value.simple_string);
}

test "invalid SET options preserve existing values and expiration and do not create keys" {
    const testing = std.testing;
    const DefaultStorage = @import("storage/default_storage.zig");
    const PersistenceState = @import("persistence_state.zig");
    const persistence = @import("persistence.zig");
    const time = @import("time.zig");

    var backend = DefaultStorage.init(testing.io, testing.allocator);
    const storage = backend.storage();
    var persistence_state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });
    var kgc = try persistence.KgcPersistence.init(testing.io, testing.allocator, &persistence_state, "set-options.kgc");
    var memory_store = store.MemoryStore.init(testing.allocator, &.{storage}, kgc.snapshot(), null);
    var data_store = memory_store.store();
    defer data_store.deinit();
    var client_state: Commander.ClientState = .{};

    const original_expiry = time.nowMs(testing.io) + 60_000;
    const expiry_argument = try std.fmt.allocPrint(testing.allocator, "{d}", .{original_expiry});
    defer testing.allocator.free(expiry_argument);
    var initial_result = try executeWithStore("SET", &.{
        "key",  "original",
        "PXAT", expiry_argument,
    }, &data_store, &client_state);
    defer initial_result.deinit();
    try testing.expectEqualStrings("OK", initial_result.value.simple_string);

    const cases = [_]struct { options: []const []const u8, expected_error: Commander.Error }{
        .{ .options = &.{"UNKNOWN"}, .expected_error = error.Syntax },
        .{ .options = &.{"bad\x00\r\noption"}, .expected_error = error.Syntax },
        .{ .options = &.{ "NX", "NX" }, .expected_error = error.Syntax },
        .{ .options = &.{ "XX", "XX" }, .expected_error = error.Syntax },
        .{ .options = &.{ "NX", "XX" }, .expected_error = error.Syntax },
        .{ .options = &.{ "XX", "NX" }, .expected_error = error.Syntax },
        .{ .options = &.{ "GET", "GET" }, .expected_error = error.Syntax },
        .{ .options = &.{ "EX", "60", "PX", "60000" }, .expected_error = error.Syntax },
        .{ .options = &.{ "EX", "60", "KEEPTTL" }, .expected_error = error.Syntax },
        .{ .options = &.{ "KEEPTTL", "EX", "60" }, .expected_error = error.Syntax },
        .{ .options = &.{ "KEEPTTL", "KEEPTTL" }, .expected_error = error.Syntax },
        .{ .options = &.{"EX"}, .expected_error = error.UnsupportedOption },
        .{ .options = &.{"PX"}, .expected_error = error.UnsupportedOption },
        .{ .options = &.{"EXAT"}, .expected_error = error.UnsupportedOption },
        .{ .options = &.{"PXAT"}, .expected_error = error.UnsupportedOption },
        .{ .options = &.{ "GET", "EX" }, .expected_error = error.UnsupportedOption },
        .{ .options = &.{ "EX", "0" }, .expected_error = error.UnsupportedOption },
        .{ .options = &.{ "PX", "-1" }, .expected_error = error.UnsupportedOption },
        .{ .options = &.{ "EXAT", "0" }, .expected_error = error.UnsupportedOption },
        .{ .options = &.{ "PXAT", "-1" }, .expected_error = error.UnsupportedOption },
        .{ .options = &.{ "EX", "" }, .expected_error = error.UnsupportedOption },
        .{ .options = &.{ "PX", "not-a-number" }, .expected_error = error.UnsupportedOption },
        .{ .options = &.{ "EX", "9223372036854775808" }, .expected_error = error.UnsupportedOption },
        .{ .options = &.{ "EX", "9223372036854775807" }, .expected_error = error.UnsupportedOption },
        .{ .options = &.{ "PX", "9223372036854775807" }, .expected_error = error.UnsupportedOption },
        .{ .options = &.{ "EXAT", "9223372036854775807" }, .expected_error = error.UnsupportedOption },
    };

    for (cases) |case| {
        for ([_][]const u8{ "key", "missing" }) |key| {
            const arguments = try testing.allocator.alloc([]const u8, case.options.len + 2);
            defer testing.allocator.free(arguments);
            arguments[0] = key;
            arguments[1] = "replacement";
            for (case.options, 2..) |option, index| arguments[index] = option;

            try testing.expectError(case.expected_error, executeWithStore("SET", arguments, &data_store, &client_state));

            var current_value = try data_store.get("key", 0) orelse return error.TestUnexpectedResult;
            defer current_value.deinit();
            try testing.expectEqualStrings("original", current_value.value.string);
            var missing_value = try data_store.get("missing", 0);
            defer if (missing_value) |*value| value.deinit();
            try testing.expect(missing_value == null);

            var tx = try storage.begin();
            defer tx.end();
            const expiration = try storage.getExp("key") orelse return error.TestUnexpectedResult;
            try testing.expectEqual(original_expiry, expiration.expires_at);
            try testing.expect(try storage.getExp("missing") == null);
        }
    }
}

test "COMMAND, COUNT, and LIST describe the available commands" {
    const testing = std.testing;
    var mock_store = MockStore.init();

    var all = try executeWithMockStore("COMMAND", &.{}, &mock_store);
    defer all.deinit();
    const details = try expectArray(all.value);

    var count = try executeWithMockStore("COMMAND", &.{"cOuNt"}, &mock_store);
    defer count.deinit();
    try testing.expectEqual(@as(i64, @intCast(details.len)), count.value.integer);

    var info_all = try executeWithMockStore("COMMAND", &.{"INFO"}, &mock_store);
    defer info_all.deinit();
    try testing.expectEqual(details.len, (try expectArray(info_all.value)).len);

    var list = try executeWithMockStore("COMMAND", &.{"LIST"}, &mock_store);
    defer list.deinit();
    const names = try expectArray(list.value);
    try testing.expectEqual(details.len, names.len);

    var found_get = false;
    var found_command = false;
    for (details) |detail| {
        const fields = try expectArray(detail);
        try testing.expectEqual(@as(usize, 10), fields.len);
        if (std.mem.eql(u8, fields[0].blob_string, "get")) found_get = true;
    }
    for (names) |name| {
        if (std.mem.eql(u8, name.blob_string, "command")) found_command = true;
    }
    try testing.expect(found_get);
    try testing.expect(found_command);
}

test "COMMAND LIST filters names by pattern and ACL category" {
    const testing = std.testing;
    var mock_store = MockStore.init();

    var pattern = try executeWithMockStore("COMMAND", &.{
        "LIST",    "FILTERBY",
        "PATTERN", "g?t",
    }, &mock_store);
    defer pattern.deinit();
    try expectBulkArray(pattern.value, &.{"get"});

    var prefix = try executeWithMockStore("COMMAND", &.{
        "LIST",    "FILTERBY",
        "PATTERN", "g*",
    }, &mock_store);
    defer prefix.deinit();
    try expectBulkArray(prefix.value, &.{"get"});

    var no_match = try executeWithMockStore("COMMAND", &.{
        "LIST",    "FILTERBY",
        "PATTERN", "absent*",
    }, &mock_store);
    defer no_match.deinit();
    try testing.expectEqual(@as(usize, 0), (try expectArray(no_match.value)).len);

    var category = try executeWithMockStore("COMMAND", &.{
        "LIST",   "FILTERBY",
        "ACLCAT", "@READ",
    }, &mock_store);
    defer category.deinit();
    try expectBulkArray(category.value, &.{ "dbsize", "get" });
}

test "COMMAND INFO reports command metadata and unknown names" {
    const testing = std.testing;
    var mock_store = MockStore.init();

    var result = try executeWithMockStore("COMMAND", &.{
        "INFO",    "gEt",
        "missing", "DEL",
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
    try testing.expect(commands[1] == .null_value and commands[1].null_value == .array);

    const del = try expectArray(commands[2]);
    try expectBulk(del[0], "del");
    try testing.expectEqual(@as(i64, -2), del[1].integer);
    try testing.expectEqual(@as(i64, -1), del[4].integer);

    var writer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer writer.deinit();
    try protocol.Resp2.resp().writeReply(&writer.writer, result.value);
    try testing.expect(std.mem.indexOf(u8, writer.written(), "*-1\r\n") != null);
}

test "COMMAND GETKEYS extracts keys without changing them" {
    var mock_store = MockStore.init();

    var get = try executeWithMockStore("COMMAND", &.{
        "GETKEYS", "gEt", "one",
    }, &mock_store);
    defer get.deinit();
    try expectBulkArray(get.value, &.{"one"});

    var set = try executeWithMockStore("COMMAND", &.{
        "GETKEYS", "SET",
        "two",     "value",
        "GET",
    }, &mock_store);
    defer set.deinit();
    try expectBulkArray(set.value, &.{"two"});

    var del = try executeWithMockStore("COMMAND", &.{
        "GETKEYS", "DEL",
        "first",   "second",
        "third",
    }, &mock_store);
    defer del.deinit();
    try expectBulkArray(del.value, &.{ "first", "second", "third" });
}

test "COMMAND GETKEYSANDFLAGS reports access for each key" {
    var mock_store = MockStore.init();

    var get = try executeWithMockStore("COMMAND", &.{
        "GETKEYSANDFLAGS", "GET", "one",
    }, &mock_store);
    defer get.deinit();
    const get_keys = try expectArray(get.value);
    try std.testing.expectEqual(@as(usize, 1), get_keys.len);
    const get_pair = try expectArray(get_keys[0]);
    try std.testing.expectEqual(@as(usize, 2), get_pair.len);
    try expectBulk(get_pair[0], "one");
    try expectBulkArray(get_pair[1], &.{ "RO", "access" });

    var set = try executeWithMockStore("COMMAND", &.{
        "GETKEYSANDFLAGS", "SET",
        "two",             "value",
    }, &mock_store);
    defer set.deinit();
    const set_pair = try expectArray((try expectArray(set.value))[0]);
    try expectBulkArray(set_pair[1], &.{ "OW", "update" });

    var set_get = try executeWithMockStore("COMMAND", &.{
        "GETKEYSANDFLAGS", "SET",
        "two",             "value",
        "GET",
    }, &mock_store);
    defer set_get.deinit();
    const set_get_pair = try expectArray((try expectArray(set_get.value))[0]);
    try expectBulkArray(set_get_pair[1], &.{ "RW", "access", "update" });

    var del = try executeWithMockStore("COMMAND", &.{
        "GETKEYSANDFLAGS", "DEL",
        "first",           "second",
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
        executeWithMockStore("COMMAND", &.{"UNKNOWN"}, &mock_store),
    );
    try testing.expectError(error.WrongNumberArguments, executeWithMockStore("COMMAND", &.{
        "COUNT", "extra",
    }, &mock_store));
    try testing.expectError(error.WrongNumberArguments, executeWithMockStore("COMMAND", &.{
        "LIST", "FILTERBY",
    }, &mock_store));
    try testing.expectError(error.Syntax, executeWithMockStore("COMMAND", &.{
        "LIST",   "FILTERBY",
        "ACLCAT", "@missing",
    }, &mock_store));
    try testing.expectError(error.UnsupportedOption, executeWithMockStore("COMMAND", &.{
        "LIST",   "FILTERBY",
        "MODULE", "module",
    }, &mock_store));
    try testing.expectError(error.WrongNumberArguments, executeWithMockStore("COMMAND", &.{
        "GETKEYS",
    }, &mock_store));
    try testing.expectError(error.UnknownCommand, executeWithMockStore("COMMAND", &.{
        "GETKEYS", "MISSING",
    }, &mock_store));
    try testing.expectError(error.WrongNumberArguments, executeWithMockStore("COMMAND", &.{
        "GETKEYS", "GET",
    }, &mock_store));
    try testing.expectError(error.Syntax, executeWithMockStore("COMMAND", &.{
        "GETKEYS", "PING",
    }, &mock_store));
}

test "supported command names keep their behavior" {
    const testing = std.testing;
    var mock_store = MockStore.init();

    mock_store.dbsize_result = 42;
    var dbsize_result = try executeWithMockStore("DBSIZE", &.{}, &mock_store);
    defer dbsize_result.deinit();
    try testing.expectEqual(@as(i64, 42), dbsize_result.value.integer);

    var del_result = try executeWithMockStore("DEL", &.{"key"}, &mock_store);
    defer del_result.deinit();
    try testing.expectEqual(@as(i64, 0), del_result.value.integer);

    var echo_result = try executeWithMockStore("ECHO", &.{"hello"}, &mock_store);
    defer echo_result.deinit();
    try testing.expectEqualStrings("hello", echo_result.value.blob_string);

    var get_result = try executeWithMockStore("GET", &.{"key"}, &mock_store);
    defer get_result.deinit();
    try testing.expect(get_result.value == .null_value and get_result.value.null_value == .bulk_string);

    var save_result = try executeWithMockStore("SAVE", &.{}, &mock_store);
    defer save_result.deinit();
    try testing.expectEqualStrings("OK", save_result.value.simple_string);

    var bgsave_result = try executeWithMockStore("BGSAVE", &.{}, &mock_store);
    defer bgsave_result.deinit();
    try testing.expectEqualStrings("Background saving started", bgsave_result.value.simple_string);

    mock_store.bgsave_result = .scheduled;
    var scheduled_bgsave_result = try executeWithMockStore("BGSAVE", &.{"sChEdUlE"}, &mock_store);
    defer scheduled_bgsave_result.deinit();
    try testing.expectEqualStrings("Background saving scheduled", scheduled_bgsave_result.value.simple_string);

    var rewrite_result = try executeWithMockStore("BGREWRITEAOF", &.{}, &mock_store);
    defer rewrite_result.deinit();
    try testing.expectEqualStrings("Background append only file rewriting started", rewrite_result.value.simple_string);

    var select_result = try executeWithMockStore("SELECT", &.{"0"}, &mock_store);
    defer select_result.deinit();
    try testing.expectEqualStrings("OK", select_result.value.simple_string);

    var set_result = try executeWithMockStore(
        "SET",
        &.{ "key", "value" },
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
        executeWithMockStore("BGSAVE", &.{"NOW"}, &mock_store),
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
