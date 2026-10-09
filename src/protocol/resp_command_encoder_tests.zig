const std = @import("std");
const testing = std.testing;
const CommandFrame = @import("command_frame.zig");
const encoder = @import("resp_command_encoder.zig");

test "command encoder writes flat bulk arrays with binary and empty arguments" {
    const cases = [_]struct { frame: CommandFrame, expected: []const u8 }{
        .{ .frame = .{ .name = "PING", .arguments = &.{} }, .expected = "*1\r\n$4\r\nPING\r\n" },
        .{ .frame = .{ .name = "SET", .arguments = &.{ "", "\x00\r\n" } }, .expected = "*3\r\n$3\r\nSET\r\n$0\r\n\r\n$3\r\n\x00\r\n\r\n" },
        .{ .frame = .{ .name = "DEL", .arguments = &.{ "first", "second", "" } }, .expected = "*4\r\n$3\r\nDEL\r\n$5\r\nfirst\r\n$6\r\nsecond\r\n$0\r\n\r\n" },
    };
    for (cases) |case| {
        var buffer: [128]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        try encoder.writeCommand(&writer, case.frame);
        try writer.flush();
        try testing.expectEqualStrings(case.expected, writer.buffered());
    }
}

const ShortSink = struct {
    bytes: [128]u8 = undefined,
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

test "command encoder completes short writes and returns partial write failures" {
    const frame: CommandFrame = .{ .name = "SET", .arguments = &.{ "", "\x00\r\n" } };
    const expected = "*3\r\n$3\r\nSET\r\n$0\r\n\r\n$3\r\n\x00\r\n\r\n";
    var sink: ShortSink = .{};
    try encoder.writeCommand(&sink.writer, frame);
    try sink.writer.flush();
    try testing.expectEqualStrings(expected, sink.bytes[0..sink.len]);

    sink = .{ .fail_after = 7 };
    try testing.expectError(error.WriteFailed, encoder.writeCommand(&sink.writer, frame));
    try testing.expectEqualStrings(expected[0..7], sink.bytes[0..sink.len]);
}
