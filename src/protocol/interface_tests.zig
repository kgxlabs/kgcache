const std = @import("std");
const protocol = @import("../protocol.zig");
const Resp = protocol.Resp;
const Reply = protocol.Reply;
const MapEntry = protocol.MapEntry;
const testing = std.testing;

fn expectReply(selected: Resp, value: Reply, expected: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try selected.writeReply(&writer, value);
    try writer.flush();
    try testing.expectEqualStrings(expected, writer.buffered());
}

test "RESP implementations share scalar bytes and preserve empty values" {
    const cases = [_]struct { value: Reply, expected: []const u8 }{
        .{ .value = .{ .simple_string = "OK" }, .expected = "+OK\r\n" },
        .{ .value = .{ .error_reply = "ERR bad option" }, .expected = "-ERR bad option\r\n" },
        .{ .value = .{ .integer = std.math.minInt(i64) }, .expected = ":-9223372036854775808\r\n" },
        .{ .value = .{ .blob_string = "\x00\r\n" }, .expected = "$3\r\n\x00\r\n\r\n" },
        .{ .value = .{ .blob_string = "" }, .expected = "$0\r\n\r\n" },
        .{ .value = .{ .array = &.{} }, .expected = "*0\r\n" },
    };
    for ([_]Resp{ protocol.Resp2.resp(), protocol.Resp3.resp() }) |selected| {
        for (cases) |case| try expectReply(selected, case.value, case.expected);
    }
}

test "RESP null hints retain RESP2 shape and become RESP3 null" {
    try expectReply(protocol.Resp2.resp(), .{ .null_value = .bulk_string }, "$-1\r\n");
    try expectReply(protocol.Resp2.resp(), .{ .null_value = .array }, "*-1\r\n");
    try expectReply(protocol.Resp3.resp(), .{ .null_value = .bulk_string }, "_\r\n");
    try expectReply(protocol.Resp3.resp(), .{ .null_value = .array }, "_\r\n");
}

test "nested arrays and maps retain the selected RESP implementation" {
    const entries = [_]MapEntry{.{
        .key = .{ .blob_string = "value" },
        .value = .{ .array = &.{ .{ .null_value = .bulk_string }, .{ .blob_string = "\x00\r\n" } } },
    }};
    const value: Reply = .{ .array = &.{ .{ .simple_string = "OK" }, .{ .map = &entries }, .{ .null_value = .array } } };
    try expectReply(protocol.Resp2.resp(), value, "*3\r\n+OK\r\n*2\r\n$5\r\nvalue\r\n*2\r\n$-1\r\n$3\r\n\x00\r\n\r\n*-1\r\n");
    try expectReply(protocol.Resp3.resp(), value, "*3\r\n+OK\r\n%1\r\n$5\r\nvalue\r\n*2\r\n_\r\n$3\r\n\x00\r\n\r\n_\r\n");
    try expectReply(protocol.Resp2.resp(), .{ .map = &.{} }, "*0\r\n");
    try expectReply(protocol.Resp3.resp(), .{ .map = &.{} }, "%0\r\n");
}

test "RESP handles keep independent version selections" {
    var first = protocol.Resp2.resp();
    const second = protocol.Resp2.resp();
    first = protocol.Resp3.resp();
    try testing.expectEqual(Resp.Version.resp3, first.version());
    try testing.expectEqual(Resp.Version.resp2, second.version());
    try expectReply(first, .{ .null_value = .bulk_string }, "_\r\n");
    try expectReply(second, .{ .null_value = .bulk_string }, "$-1\r\n");
}

test "invalid nested line text is rejected before any output" {
    const invalid = [_]Reply{
        .{ .simple_string = "bad\rtext" },
        .{ .simple_string = "bad\ntext" },
        .{ .error_reply = "ERR bad\rtext" },
        .{ .error_reply = "ERR bad\ntext" },
    };
    for ([_]Resp{ protocol.Resp2.resp(), protocol.Resp3.resp() }) |selected| {
        for (invalid) |bad| {
            const entries = [_]MapEntry{.{ .key = .{ .blob_string = "key" }, .value = bad }};
            const value: Reply = .{ .array = &.{ .{ .simple_string = "OK" }, .{ .map = &entries } } };
            var buffer: [128]u8 = undefined;
            var writer = std.Io.Writer.fixed(&buffer);
            try testing.expectError(error.InvalidLineText, selected.writeReply(&writer, value));
            try testing.expectEqual(@as(usize, 0), writer.end);
        }
    }
}

test "overflowing map counts are rejected before output or entry access" {
    const entry: MapEntry = .{ .key = .{ .integer = 1 }, .value = .{ .integer = 2 } };
    var count: usize = std.math.maxInt(usize) / 2 + 1;
    std.mem.doNotOptimizeAway(&count);
    const entries = @as([*]const MapEntry, @ptrCast(&entry))[0..count];
    for ([_]Resp{ protocol.Resp2.resp(), protocol.Resp3.resp() }) |selected| {
        var buffer: [32]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        try testing.expectError(error.LengthOverflow, selected.writeReply(&writer, .{ .map = entries }));
        try testing.expectEqual(@as(usize, 0), writer.end);
    }
}

const ShortSink = struct {
    bytes: [256]u8 = undefined,
    len: usize = 0,
    fail_after: ?usize = null,
    writer: std.Io.Writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },

    fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *ShortSink = @fieldParentPtr("writer", writer);
        for (data[0 .. data.len - 1]) |bytes| {
            if (bytes.len != 0) return self.consume(bytes);
        }
        const last = data[data.len - 1];
        if (splat != 0 and last.len != 0) return self.consume(last);
        return 0;
    }

    fn consume(self: *ShortSink, bytes: []const u8) std.Io.Writer.Error!usize {
        const limit = self.fail_after orelse self.bytes.len;
        if (self.len >= limit) return error.WriteFailed;
        const count = @min(bytes.len, 3, limit - self.len);
        @memcpy(self.bytes[self.len..][0..count], bytes[0..count]);
        self.len += count;
        return count;
    }
};

test "RESP writes finish through a short-writing sink" {
    const value: Reply = .{ .array = &.{ .{ .blob_string = "\x00\r\n" }, .{ .integer = 12345 } } };
    const expected = "*2\r\n$3\r\n\x00\r\n\r\n:12345\r\n";
    for ([_]Resp{ protocol.Resp2.resp(), protocol.Resp3.resp() }) |selected| {
        var sink: ShortSink = .{};
        try selected.writeReply(&sink.writer, value);
        try sink.writer.flush();
        try testing.expectEqualStrings(expected, sink.bytes[0..sink.len]);
    }
}

test "RESP output failure returns the partial prefix without appending a reply" {
    const value: Reply = .{ .array = &.{ .{ .blob_string = "abc" }, .{ .integer = 12345 } } };
    const expected = "*2\r\n$3\r\nabc\r\n:12345\r\n";
    for ([_]Resp{ protocol.Resp2.resp(), protocol.Resp3.resp() }) |selected| {
        var sink: ShortSink = .{ .fail_after = 7 };
        try testing.expectError(error.WriteFailed, selected.writeReply(&sink.writer, value));
        try testing.expectEqualStrings(expected[0..7], sink.bytes[0..sink.len]);
    }
}
