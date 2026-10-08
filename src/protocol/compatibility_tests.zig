const std = @import("std");
const commander = @import("../commander.zig");
const MockStore = @import("../store/mock_store.zig");
const ClientState = @import("../client_state.zig");
const AofEncoder = @import("../codec/aof_encoder.zig");
const Journal = @import("../persistence/journal_interface.zig");
const protocol = @import("../protocol.zig");
const testing = std.testing;

const command_fixtures = [_]struct { request: []const u8, reply: []const u8 }{
    .{ .request = @embedFile("fixtures/ping.request.resp"), .reply = @embedFile("fixtures/ping.reply.resp") },
    .{ .request = @embedFile("fixtures/echo-binary.request.resp"), .reply = @embedFile("fixtures/echo-binary.reply.resp") },
    .{ .request = @embedFile("fixtures/get-missing.request.resp"), .reply = @embedFile("fixtures/get-missing.reply.resp") },
    .{ .request = @embedFile("fixtures/set-get-missing.request.resp"), .reply = @embedFile("fixtures/set-get-missing.reply.resp") },
    .{ .request = @embedFile("fixtures/command-count.request.resp"), .reply = @embedFile("fixtures/command-count.reply.resp") },
    .{ .request = @embedFile("fixtures/command-list.request.resp"), .reply = @embedFile("fixtures/command-list.reply.resp") },
    .{ .request = @embedFile("fixtures/command-info-get.request.resp"), .reply = @embedFile("fixtures/command-info-get.reply.resp") },
    .{ .request = @embedFile("fixtures/command-info-unknown.request.resp"), .reply = @embedFile("fixtures/command-info-unknown.reply.resp") },
    .{ .request = @embedFile("fixtures/command-getkeys.request.resp"), .reply = @embedFile("fixtures/command-getkeys.reply.resp") },
};

test "captured command replies preserve legacy and semantic RESP2 bytes" {
    for (command_fixtures) |fixture| {
        var decoded = switch (try protocol.request_decoder.decode(fixture.request, testing.allocator, protocol.request_decoder.aof_limits)) {
            .complete => |complete| complete,
            .incomplete => return error.TestUnexpectedResult,
        };
        defer decoded.deinit(testing.allocator);
        const command = try commander.init(testing.allocator, decoded.frame);
        defer command.deinit();
        var mock = MockStore.init();
        mock.num_databases_result = 16;
        var data_store = mock.store();
        var state = ClientState.init();
        var result = try command.execute(testing.io, &data_store, &state);
        defer result.deinit();
        var buffer: [4096]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        try state.resp.writeReply(&writer, result.value);
        try writer.flush();
        try testing.expectEqualStrings(fixture.reply, writer.buffered());
    }
}

test "captured AOF mutation bytes preserve SELECT tracking and binary arguments" {
    var encoder = AofEncoder.init();
    const cases = [_]struct { event: Journal.WriteEvent, expected: []const u8 }{
        .{ .event = .{ .put = .{ .db_index = 0, .key = "fruit", .value = .{ .string = "apple" }, .expires_at = null } }, .expected = @embedFile("fixtures/aof-first-set.aof") },
        .{ .event = .{ .put = .{ .db_index = 0, .key = "\x00\r\n", .value = .{ .string = "" }, .expires_at = null } }, .expected = @embedFile("fixtures/aof-same-db-binary.aof") },
        .{ .event = .{ .put = .{ .db_index = 2, .key = "fruit", .value = .{ .string = "pear" }, .expires_at = 1_700_000_000_123 } }, .expected = @embedFile("fixtures/aof-switch-expiry.aof") },
        .{ .event = .{ .remove = .{ .db_index = 2, .key = "fruit" } }, .expected = @embedFile("fixtures/aof-delete.aof") },
        .{ .event = .{ .put = .{ .db_index = 2, .key = "", .value = .{ .string = "" }, .expires_at = null } }, .expected = @embedFile("fixtures/aof-empty.aof") },
    };
    for (cases) |case| {
        const encoded = try encoder.encodeWriteEvent(testing.allocator, case.event);
        defer encoder.deinit(testing.allocator, encoded.bytes);
        try testing.expectEqualStrings(case.expected, encoded.bytes);
        encoder.commitDb(encoded.db_index);
    }
}

test "captured AOF rewrite bytes preserve expiration and empty binary arguments" {
    var encoder = AofEncoder.init();
    const encoded = try encoder.encodeRewriteEntry(testing.allocator, .{
        .db_index = 3,
        .key = "",
        .value = .{ .string = "\x00\r\n" },
        .expires_at = 1_700_000_000_123,
    });
    defer encoder.deinit(testing.allocator, encoded.bytes);
    try testing.expectEqualStrings(@embedFile("fixtures/aof-rewrite-binary.aof"), encoded.bytes);
}
