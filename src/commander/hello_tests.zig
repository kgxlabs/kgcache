const std = @import("std");
const build_options = @import("build_options");
const commander = @import("../commander.zig");
const connection = @import("../connection.zig");
const protocol = @import("../protocol.zig");
const MockStore = @import("../store/mock_store.zig");
const testing = std.testing;

test "HELLO reports the caller's metadata in the current protocol" {
    const context: connection.ConnectionContext = .{ .id = std.math.maxInt(i64) };
    var mock = MockStore.init();
    var data_store = mock.store();
    for ([_]protocol.Resp{ protocol.Resp2.resp(), protocol.Resp3.resp() }) |selected| {
        for ([_][]const u8{ "HELLO", "hello", "hElLo" }) |name| {
            var state = connection.ClientState.initWithConnection(&context);
            state.db_index = 7;
            state.resp = selected;
            const command = try commander.init(testing.allocator, .{ .name = name, .arguments = &.{} });
            var result = command.execute(testing.io, &data_store, &state) catch |err| {
                command.deinit();
                return err;
            };
            command.deinit();
            defer result.deinit();

            try testing.expect(result.value == .map);
            const entries = result.value.map;
            const keys = [_][]const u8{ "server", "version", "proto", "id", "mode", "role", "modules" };
            try testing.expectEqual(keys.len, entries.len);
            for (entries, keys) |entry, key| try testing.expectEqualStrings(key, entry.key.blob_string);
            try testing.expectEqualStrings("kgcache", entries[0].value.blob_string);
            try testing.expectEqualStrings(build_options.version, entries[1].value.blob_string);
            try testing.expectEqual(@as(i64, @intFromEnum(selected.version())), entries[2].value.integer);
            try testing.expectEqual(@as(i64, std.math.maxInt(i64)), entries[3].value.integer);
            try testing.expectEqualStrings("standalone", entries[4].value.blob_string);
            try testing.expectEqualStrings("master", entries[5].value.blob_string);
            try testing.expectEqual(0, entries[6].value.array.len);
            try testing.expect(result.owned_arena != null);
            try testing.expectEqual(7, state.db_index);
            try testing.expectEqual(selected, state.resp);
            try testing.expect(state.connection_context.? == &context);

            var expected_buffer: [512]u8 = undefined;
            const expected = try std.fmt.bufPrint(
                &expected_buffer,
                "{s}$6\r\nserver\r\n$7\r\nkgcache\r\n$7\r\nversion\r\n${d}\r\n{s}\r\n" ++
                    "$5\r\nproto\r\n:{d}\r\n$2\r\nid\r\n:9223372036854775807\r\n" ++
                    "$4\r\nmode\r\n$10\r\nstandalone\r\n$4\r\nrole\r\n$6\r\nmaster\r\n$7\r\nmodules\r\n*0\r\n",
                .{ if (selected.version() == .resp2) "*14\r\n" else "%7\r\n", build_options.version.len, build_options.version, @intFromEnum(selected.version()) },
            );
            var buffer: [512]u8 = undefined;
            var writer = std.Io.Writer.fixed(&buffer);
            try selected.writeReply(&writer, result.value);
            try writer.flush();
            try testing.expectEqualStrings(expected, writer.buffered());
        }
    }
}

test "HELLO metadata allocation failures release owners and preserve state" {
    try testing.checkAllAllocationFailures(testing.allocator, metadataAllocation, .{});
}

fn metadataAllocation(allocator: std.mem.Allocator) !void {
    const context: connection.ConnectionContext = .{ .id = 42 };
    var state = connection.ClientState.initWithConnection(&context);
    state.db_index = 2;
    state.resp = protocol.Resp3.resp();
    defer {
        testing.expectEqual(2, state.db_index) catch unreachable;
        testing.expectEqual(protocol.Resp3.resp(), state.resp) catch unreachable;
        testing.expect(state.connection_context.? == &context) catch unreachable;
    }
    var mock = MockStore.init();
    var data_store = mock.store();
    const command = try commander.init(allocator, .{ .name = "HELLO", .arguments = &.{} });
    defer command.deinit();
    var result = try command.execute(testing.io, &data_store, &state);
    defer result.deinit();
}

test "HELLO rejects arguments without changing the caller's state" {
    const context: connection.ConnectionContext = .{ .id = 42 };
    var state = connection.ClientState.initWithConnection(&context);
    state.db_index = 2;
    state.resp = protocol.Resp3.resp();
    var mock = MockStore.init();
    var data_store = mock.store();
    const cases = [_][]const []const u8{ &.{"2"}, &.{"3"}, &.{ "2", "AUTH", "user", "password" }, &.{ "3", "SETNAME", "name" }, &.{ "extra", "arguments" } };
    for (cases) |arguments| {
        const command = try commander.init(testing.allocator, .{ .name = "HELLO", .arguments = arguments });
        defer command.deinit();
        try testing.expectError(error.UnsupportedOption, command.execute(testing.io, &data_store, &state));
        try testing.expectEqual(2, state.db_index);
        try testing.expectEqual(protocol.Resp3.resp(), state.resp);
        try testing.expect(state.connection_context.? == &context);
    }
}

test "HELLO rejects execution without a connection context" {
    var state = connection.ClientState.init();
    var mock = MockStore.init();
    var data_store = mock.store();
    const command = try commander.init(testing.allocator, .{ .name = "HELLO", .arguments = &.{} });
    defer command.deinit();
    try testing.expectError(error.MissingConnectionContext, command.execute(testing.io, &data_store, &state));
}
