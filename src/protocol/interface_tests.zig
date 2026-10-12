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

test "verbatim has exact RESP2 bulk and RESP3 txt framing" {
    const cases = [_]struct { text: []const u8, resp2: []const u8, resp3: []const u8 }{
        .{ .text = "x\n", .resp2 = "$2\r\nx\n\r\n", .resp3 = "=6\r\ntxt:x\n\r\n" },
        .{ .text = "", .resp2 = "$0\r\n\r\n", .resp3 = "=4\r\ntxt:\r\n" },
        .{ .text = "a\r\nb\n", .resp2 = "$5\r\na\r\nb\n\r\n", .resp3 = "=9\r\ntxt:a\r\nb\n\r\n" },
        .{ .text = "\xc3\xa9\n", .resp2 = "$3\r\n\xc3\xa9\n\r\n", .resp3 = "=7\r\ntxt:\xc3\xa9\n\r\n" },
    };
    for (cases) |case| {
        try expectReply(protocol.Resp2.resp(), .{ .verbatim = case.text }, case.resp2);
        try expectReply(protocol.Resp3.resp(), .{ .verbatim = case.text }, case.resp3);
    }
}

test "nested verbatim retains the selected RESP implementation" {
    const entries = [_]MapEntry{.{
        .key = .{ .blob_string = "info" },
        .value = .{ .verbatim = "x\n" },
    }};
    const value: Reply = .{ .array = &.{.{ .map = &entries }} };
    try expectReply(protocol.Resp2.resp(), value, "*1\r\n*2\r\n$4\r\ninfo\r\n$2\r\nx\n\r\n");
    try expectReply(protocol.Resp3.resp(), value, "*1\r\n%1\r\n$4\r\ninfo\r\n=6\r\ntxt:x\n\r\n");
}

test "verbatim length includes the prefix and rejects arithmetic overflow" {
    try testing.expectEqual(4, try Resp.verbatimLength(0));
    try testing.expectEqual(6, try Resp.verbatimLength(2));
    try testing.expectError(error.LengthOverflow, Resp.verbatimLength(std.math.maxInt(usize)));
    if (@bitSizeOf(usize) >= 64) {
        const signed_max: usize = @intCast(std.math.maxInt(i64));
        try testing.expectEqual(signed_max, try Resp.verbatimLength(signed_max - 4));
        try testing.expectError(error.LengthOverflow, Resp.verbatimLength(signed_max - 3));
    }
}

test "oversized nested verbatim is rejected before any output" {
    if (@bitSizeOf(usize) < 64) return;
    const signed_max: usize = @intCast(std.math.maxInt(i64));
    const cases = [_]struct { selected: Resp, length: usize }{
        .{ .selected = protocol.Resp2.resp(), .length = signed_max + 1 },
        .{ .selected = protocol.Resp3.resp(), .length = signed_max - 3 },
    };
    for (cases) |case| {
        const text = "x".ptr[0..case.length];
        const entries = [_]MapEntry{.{
            .key = .{ .blob_string = "info" },
            .value = .{ .verbatim = text },
        }};
        const value: Reply = .{ .array = &.{ .{ .simple_string = "OK" }, .{ .map = &entries } } };
        var buffer: [128]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        try testing.expectError(error.LengthOverflow, case.selected.writeReply(&writer, value));
        try testing.expectEqualStrings("", writer.buffered());
    }
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

test "server metadata maps have exact RESP2 and RESP3 wire shapes" {
    const prefix = "$6\r\nserver\r\n$7\r\nkgcache\r\n$7\r\nversion\r\n$4\r\ntest\r\n$5\r\nproto\r\n";
    const suffix = "$2\r\nid\r\n:42\r\n$4\r\nmode\r\n$10\r\nstandalone\r\n$4\r\nrole\r\n$6\r\nmaster\r\n$7\r\nmodules\r\n*0\r\n";
    for ([_]Resp{ protocol.Resp2.resp(), protocol.Resp3.resp() }) |selected| {
        const entries = [_]MapEntry{
            .{ .key = .{ .blob_string = "server" }, .value = .{ .blob_string = "kgcache" } },
            .{ .key = .{ .blob_string = "version" }, .value = .{ .blob_string = "test" } },
            .{ .key = .{ .blob_string = "proto" }, .value = .{ .integer = @intFromEnum(selected.version()) } },
            .{ .key = .{ .blob_string = "id" }, .value = .{ .integer = 42 } },
            .{ .key = .{ .blob_string = "mode" }, .value = .{ .blob_string = "standalone" } },
            .{ .key = .{ .blob_string = "role" }, .value = .{ .blob_string = "master" } },
            .{ .key = .{ .blob_string = "modules" }, .value = .{ .array = &.{} } },
        };
        const expected = if (selected.version() == .resp2) "*14\r\n" ++ prefix ++ ":2\r\n" ++ suffix else "%7\r\n" ++ prefix ++ ":3\r\n" ++ suffix;
        try expectReply(selected, .{ .map = &entries }, expected);
    }
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
            try testing.expectEqualStrings("", writer.buffered());
        }
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

test "verbatim finishes short writes and preserves failed prefixes" {
    const cases = [_]struct { selected: Resp, expected: []const u8 }{
        .{ .selected = protocol.Resp2.resp(), .expected = "$2\r\nx\n\r\n" },
        .{ .selected = protocol.Resp3.resp(), .expected = "=6\r\ntxt:x\n\r\n" },
    };
    for (cases) |case| {
        var sink: ShortSink = .{};
        try case.selected.writeReply(&sink.writer, .{ .verbatim = "x\n" });
        try sink.writer.flush();
        try testing.expectEqualStrings(case.expected, sink.bytes[0..sink.len]);

        for ([_]usize{ 1, 5, case.expected.len - 1 }) |limit| {
            var failing: ShortSink = .{ .fail_after = limit };
            try testing.expectError(error.WriteFailed, case.selected.writeReply(&failing.writer, .{ .verbatim = "x\n" }));
            try testing.expectEqualStrings(case.expected[0..limit], failing.bytes[0..failing.len]);
        }
    }
}
