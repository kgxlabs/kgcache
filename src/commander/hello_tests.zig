const std = @import("std");
const build_options = @import("build_options");
const commander = @import("../commander.zig");
const connection = @import("../connection.zig");
const protocol = @import("../protocol.zig");
const MockStore = @import("../store/mock_store.zig");
const TestNetwork = @import("../connection/test_network.zig");
const testing = std.testing;

test "HELLO reports the caller's metadata in the current protocol" {
    const context = TestNetwork.identityContext(std.math.maxInt(i64));
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

            try expectMetadata(selected, result, context.id);
            try testing.expectEqual(7, state.db_index);
            try testing.expectEqual(selected, state.resp);
            try testing.expect(state.connection_context.? == &context);
        }
    }
}

test "HELLO switches repeatedly and versionless requests keep the selected handle" {
    const context = TestNetwork.identityContext(42);
    var state = connection.ClientState.initWithConnection(&context);
    state.db_index = 7;
    var mock = MockStore.init();
    var data_store = mock.store();
    const cases = [_]struct { arguments: []const []const u8, selected: protocol.Resp }{
        .{ .arguments = &.{"3"}, .selected = protocol.Resp3.resp() },
        .{ .arguments = &.{"3"}, .selected = protocol.Resp3.resp() },
        .{ .arguments = &.{}, .selected = protocol.Resp3.resp() },
        .{ .arguments = &.{"2"}, .selected = protocol.Resp2.resp() },
        .{ .arguments = &.{"2"}, .selected = protocol.Resp2.resp() },
        .{ .arguments = &.{}, .selected = protocol.Resp2.resp() },
        .{ .arguments = &.{"3"}, .selected = protocol.Resp3.resp() },
        .{ .arguments = &.{"2"}, .selected = protocol.Resp2.resp() },
    };
    for (cases) |case| {
        const command = try commander.init(testing.allocator, .{ .name = "hElLo", .arguments = case.arguments });
        defer command.deinit();
        var result = try command.execute(testing.io, &data_store, &state);
        defer result.deinit();
        try testing.expectEqual(case.selected, state.resp);
        try expectMetadata(state.resp, result, context.id);
        try testing.expectEqual(7, state.db_index);
        try testing.expect(state.connection_context.? == &context);
    }
}

test "HELLO metadata allocation failures release owners and preserve the prior handle" {
    for ([_]protocol.Resp{ protocol.Resp2.resp(), protocol.Resp3.resp() }) |current| {
        try testing.checkAllAllocationFailures(testing.allocator, metadataAllocation, .{ current, @as([]const []const u8, &.{}), current });
        try testing.checkAllAllocationFailures(testing.allocator, metadataAllocation, .{ current, @as([]const []const u8, &.{"2"}), protocol.Resp2.resp() });
        try testing.checkAllAllocationFailures(testing.allocator, metadataAllocation, .{ current, @as([]const []const u8, &.{"3"}), protocol.Resp3.resp() });
    }
}

fn metadataAllocation(allocator: std.mem.Allocator, current: protocol.Resp, arguments: []const []const u8, selected: protocol.Resp) !void {
    const context = TestNetwork.identityContext(42);
    var state = connection.ClientState.initWithConnection(&context);
    state.db_index = 2;
    state.resp = current;
    var succeeded = false;
    defer {
        testing.expectEqual(2, state.db_index) catch unreachable;
        testing.expectEqual(if (succeeded) selected else current, state.resp) catch unreachable;
        testing.expect(state.connection_context.? == &context) catch unreachable;
    }
    var mock = MockStore.init();
    var data_store = mock.store();
    const command = try commander.init(allocator, .{ .name = "HELLO", .arguments = arguments });
    defer command.deinit();
    var result = try command.execute(testing.io, &data_store, &state);
    defer result.deinit();
    succeeded = true;
    try expectMetadata(state.resp, result, context.id);
}

test "invalid HELLO requests preserve state and are rejected before metadata allocation" {
    const context = TestNetwork.identityContext(42);
    var mock = MockStore.init();
    var data_store = mock.store();
    const cases = [_]struct { arguments: []const []const u8, err: anyerror }{
        .{ .arguments = &.{"1"}, .err = error.UnsupportedProtocolVersion },
        .{ .arguments = &.{"4"}, .err = error.UnsupportedProtocolVersion },
        .{ .arguments = &.{"0"}, .err = error.UnsupportedProtocolVersion },
        .{ .arguments = &.{"-1"}, .err = error.UnsupportedProtocolVersion },
        .{ .arguments = &.{"9223372036854775807"}, .err = error.UnsupportedProtocolVersion },
        .{ .arguments = &.{"9223372036854775808"}, .err = error.MalformedCommandRequest },
        .{ .arguments = &.{""}, .err = error.MalformedCommandRequest },
        .{ .arguments = &.{"three"}, .err = error.MalformedCommandRequest },
        .{ .arguments = &.{"2.0"}, .err = error.MalformedCommandRequest },
        .{ .arguments = &.{" 3"}, .err = error.MalformedCommandRequest },
        .{ .arguments = &.{ "2", "AUTH", "user", "password" }, .err = error.UnsupportedOption },
        .{ .arguments = &.{ "3", "SETNAME", "name" }, .err = error.UnsupportedOption },
        .{ .arguments = &.{ "3", "auth" }, .err = error.UnsupportedOption },
        .{ .arguments = &.{ "2", "setname" }, .err = error.UnsupportedOption },
        .{ .arguments = &.{ "3", "extra", "arguments" }, .err = error.UnsupportedOption },
        .{ .arguments = &.{ "2", "3" }, .err = error.UnsupportedOption },
    };
    for ([_]protocol.Resp{ protocol.Resp2.resp(), protocol.Resp3.resp() }) |current| {
        for (cases) |case| {
            var state = connection.ClientState.initWithConnection(&context);
            state.db_index = 2;
            state.resp = current;
            var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
            const command = try commander.init(failing.allocator(), .{ .name = "HELLO", .arguments = case.arguments });
            defer command.deinit();
            try testing.expectError(case.err, command.execute(testing.io, &data_store, &state));
            try testing.expectEqual(2, state.db_index);
            try testing.expectEqual(current, state.resp);
            try testing.expect(state.connection_context.? == &context);
        }
    }
}

fn expectMetadata(selected: protocol.Resp, result: commander.Commander.Result, id: u64) !void {
    try testing.expect(result.value == .map);
    const entries = result.value.map;
    const keys = [_][]const u8{ "server", "version", "proto", "id", "mode", "role", "modules" };
    try testing.expectEqual(keys.len, entries.len);
    for (entries, keys) |entry, key| try testing.expectEqualStrings(key, entry.key.blob_string);
    try testing.expectEqualStrings("kgcache", entries[0].value.blob_string);
    try testing.expectEqualStrings(build_options.version, entries[1].value.blob_string);
    try testing.expectEqual(@as(i64, @intFromEnum(selected.version())), entries[2].value.integer);
    try testing.expectEqual(@as(i64, @intCast(id)), entries[3].value.integer);
    try testing.expectEqualStrings("standalone", entries[4].value.blob_string);
    try testing.expectEqualStrings("master", entries[5].value.blob_string);
    try testing.expectEqual(0, entries[6].value.array.len);
    try testing.expect(result.owned_arena != null);

    var expected_buffer: [512]u8 = undefined;
    const expected = try std.fmt.bufPrint(
        &expected_buffer,
        "{s}$6\r\nserver\r\n$7\r\nkgcache\r\n$7\r\nversion\r\n${d}\r\n{s}\r\n" ++
            "$5\r\nproto\r\n:{d}\r\n$2\r\nid\r\n:{d}\r\n" ++
            "$4\r\nmode\r\n$10\r\nstandalone\r\n$4\r\nrole\r\n$6\r\nmaster\r\n$7\r\nmodules\r\n*0\r\n",
        .{ if (selected.version() == .resp2) "*14\r\n" else "%7\r\n", build_options.version.len, build_options.version, @intFromEnum(selected.version()), id },
    );
    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try selected.writeReply(&writer, result.value);
    try writer.flush();
    try testing.expectEqualStrings(expected, writer.buffered());
}

test "HELLO rejects execution without a connection context" {
    var state = connection.ClientState.init();
    var mock = MockStore.init();
    var data_store = mock.store();
    for ([_][]const []const u8{ &.{}, &.{"2"}, &.{"3"} }) |arguments| {
        const command = try commander.init(testing.allocator, .{ .name = "HELLO", .arguments = arguments });
        defer command.deinit();
        try testing.expectError(error.MissingConnectionContext, command.execute(testing.io, &data_store, &state));
        try testing.expectEqual(protocol.Resp2.resp(), state.resp);
    }
}
