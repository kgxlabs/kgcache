const std = @import("std");
const legacy = @import("../resp.zig");
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

fn semanticReply(allocator: std.mem.Allocator, value: legacy.RESPValue) std.mem.Allocator.Error!protocol.Reply {
    return switch (value) {
        .simple_string => |text| .{ .simple_string = text },
        .simple_error => |text| .{ .error_reply = text },
        .integer => |number| .{ .integer = number },
        .bulk_string => |maybe| if (maybe) |bytes| .{ .blob_string = bytes } else .{ .null_value = .bulk_string },
        .array => |maybe| if (maybe) |items| blk: {
            const replies = try allocator.alloc(protocol.Reply, items.len);
            for (items, replies) |item, *reply| reply.* = try semanticReply(allocator, item);
            break :blk .{ .array = replies };
        } else .{ .null_value = .array },
    };
}

test "captured command replies preserve legacy and semantic RESP2 bytes" {
    for (command_fixtures) |fixture| {
        var parser = legacy.parser(fixture.request);
        const request = try parser.parse(testing.allocator);
        defer parser.deinit(testing.allocator, request);
        const command = try commander.init(testing.allocator, request);
        defer command.deinit();
        var mock = MockStore.init();
        mock.num_databases_result = 16;
        var data_store = mock.store();
        var state = ClientState.init();
        var result = try command.execute(testing.io, &data_store, &state);
        defer result.deinit();
        const serializer = legacy.serializer();
        const bytes = try serializer.serialize(testing.allocator, result.value);
        defer serializer.deinit(testing.allocator, bytes);
        try testing.expectEqualStrings(fixture.reply, bytes);

        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const value = try semanticReply(arena.allocator(), result.value);
        var buffer: [4096]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        try protocol.Resp2.resp().writeReply(&writer, value);
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
