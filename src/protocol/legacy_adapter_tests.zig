const std = @import("std");
const testing = std.testing;
const legacy = @import("../resp.zig");
const adapter = @import("legacy_adapter.zig");
const Resp2 = @import("resp2.zig");
const Resp3 = @import("resp3.zig");
const Commander = @import("../commander/interface.zig");
const object = @import("../object.zig");
const request_decoder = @import("request_decoder.zig");

test "legacy command frames borrow binary and empty argument bytes" {
    var name = [_]u8{ 'E', 'C', 'H', 'O' };
    var binary = [_]u8{ 0, '\r', '\n' };
    var items = [_]legacy.RESPValue{
        .{ .bulk_string = &name },
        .{ .bulk_string = "" },
        .{ .bulk_string = &binary },
    };
    const frame = try adapter.commandFrame(testing.allocator, .{ .array = &items });
    defer testing.allocator.free(frame.arguments);

    try testing.expectEqualStrings("ECHO", frame.name);
    try testing.expectEqual(@as(usize, 2), frame.arguments.len);
    try testing.expectEqualStrings("", frame.arguments[0]);
    try testing.expectEqualStrings("\x00\r\n", frame.arguments[1]);
    try testing.expect(frame.name.ptr == &name);
    try testing.expect(frame.arguments[1].ptr == &binary);
}

test "legacy command adapter requires a nonempty non-null array" {
    var empty: [0]legacy.RESPValue = .{};
    try testing.expectError(error.ExpectedArray, adapter.commandFrame(testing.allocator, .{ .bulk_string = "PING" }));
    try testing.expectError(error.InvalidArrayLength, adapter.commandFrame(testing.allocator, .{ .array = null }));
    try testing.expectError(error.EmptyArray, adapter.commandFrame(testing.allocator, .{ .array = &empty }));
}

test "legacy command adapter validates every element before allocating" {
    var nested = [_]legacy.RESPValue{.{ .bulk_string = "fruit" }};
    const invalid_items = [_]legacy.RESPValue{
        .{ .bulk_string = null },
        .{ .array = null },
        .{ .array = &nested },
        .{ .integer = 42 },
        .{ .simple_string = "fruit" },
        .{ .simple_error = "ERR" },
    };

    for (invalid_items) |invalid| {
        for (0..3) |index| {
            var items = [_]legacy.RESPValue{
                .{ .bulk_string = "DEL" },
                .{ .bulk_string = "fruit" },
                .{ .bulk_string = "apple" },
            };
            items[index] = invalid;
            var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
            const expected = if (invalid == .bulk_string) error.InvalidBulkLength else error.ExpectedBulkString;
            try testing.expectError(expected, adapter.commandFrame(failing.allocator(), .{ .array = &items }));
        }
    }
}

test "legacy command adapter leaves empty names for dispatch" {
    var items = [_]legacy.RESPValue{.{ .bulk_string = "" }};
    const frame = try adapter.commandFrame(testing.allocator, .{ .array = &items });
    defer testing.allocator.free(frame.arguments);
    try testing.expectEqualStrings("", frame.name);
    try testing.expectEqual(@as(usize, 0), frame.arguments.len);
}

test "legacy command adapter returns argument allocation failure" {
    var items = [_]legacy.RESPValue{
        .{ .bulk_string = "ECHO" },
        .{ .bulk_string = "hello" },
    };
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, adapter.commandFrame(failing.allocator(), .{ .array = &items }));
}

test "legacy reply bridge preserves null shapes and the selected protocol" {
    var empty: [0]legacy.RESPValue = .{};
    var items = [_]legacy.RESPValue{
        .{ .bulk_string = null },
        .{ .array = null },
        .{ .bulk_string = "" },
        .{ .array = &empty },
        .{ .bulk_string = "\x00\r\n" },
    };
    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try adapter.writeReply(testing.allocator, Resp2.resp(), &writer, .{ .array = &items });
    try testing.expectEqualStrings("*5\r\n$-1\r\n*-1\r\n$0\r\n\r\n*0\r\n$3\r\n\x00\r\n\r\n", writer.buffered());

    writer = std.Io.Writer.fixed(&buffer);
    try adapter.writeReply(testing.allocator, Resp3.resp(), &writer, .{ .array = &items });
    try testing.expectEqualStrings("*5\r\n_\r\n_\r\n$0\r\n\r\n*0\r\n$3\r\n\x00\r\n\r\n", writer.buffered());
}

test "legacy reply bridge keeps the original owned result alive" {
    var result = try Commander.Result.owned(try object.Owned.clone(testing.allocator, .{ .string = "\x00\r\n" }));
    defer result.deinit();
    var buffer: [32]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try adapter.writeReply(testing.allocator, Resp2.resp(), &writer, .{ .bulk_string = result.value.blob_string });
    try testing.expectEqualStrings("$3\r\n\x00\r\n\r\n", writer.buffered());
    try testing.expectEqualStrings("\x00\r\n", result.owned_object.?.value.string);
}

test "legacy reply bridge cleans up after validation and write failures" {
    var items = [_]legacy.RESPValue{
        .{ .integer = 42 },
        .{ .simple_error = "ERR\r\ninvalid" },
    };
    var buffer: [32]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try testing.expectError(error.InvalidLineText, adapter.writeReply(testing.allocator, Resp2.resp(), &writer, .{ .array = &items }));
    try testing.expectEqual(@as(usize, 0), writer.end);

    items[1] = .{ .simple_string = "OK" };
    var no_space: [0]u8 = .{};
    writer = std.Io.Writer.fixed(&no_space);
    try testing.expectError(error.WriteFailed, adapter.writeReply(testing.allocator, Resp2.resp(), &writer, .{ .array = &items }));
}

test "legacy reply bridge cleans up every nested allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, writeNestedReply, .{});
}

fn writeNestedReply(allocator: std.mem.Allocator) !void {
    var leaf = [_]legacy.RESPValue{
        .{ .bulk_string = "\x00\r\n" },
        .{ .integer = 7 },
        .{ .array = null },
    };
    var items = [_]legacy.RESPValue{.{ .array = &leaf }} ** 64;
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try adapter.writeReply(allocator, Resp2.resp(), &writer, .{ .array = &items });
    try testing.expectEqualStrings("*64\r\n" ++ ("*3\r\n$3\r\n\x00\r\n\r\n:7\r\n*-1\r\n" ** 64), writer.buffered());
}

test "shared decoder consumes one frame and borrows its binary bodies" {
    const first = "*3\r\n$4\r\nECHO\r\n$0\r\n\r\n$3\r\n\x00\r\n\r\n";
    var input = (first ++ "*1\r\n$4\r\nPING\r\n").*;
    const outcome = try request_decoder.decode(&input, testing.allocator, request_decoder.network_limits);
    var decoded = outcome.complete;
    defer decoded.deinit(testing.allocator);

    try testing.expectEqual(first.len, decoded.consumed);
    try testing.expectEqualStrings("ECHO", decoded.frame.name);
    try testing.expectEqualStrings("", decoded.frame.arguments[0]);
    try testing.expectEqualStrings("\x00\r\n", decoded.frame.arguments[1]);
    try testing.expect(decoded.frame.name.ptr == input[8..].ptr);
    const binary_offset = std.mem.indexOfScalar(u8, &input, 0).?;
    try testing.expect(decoded.frame.arguments[1].ptr == input[binary_offset..].ptr);
}

test "shared decoder enforces caller limits on the first frame" {
    const input = "*2\r\n$4\r\nECHO\r\n$0\r\n\r\n";
    try testing.expectError(error.FrameTooLarge, request_decoder.decode(input, testing.allocator, .{ .max_frame_bytes = input.len - 1, .max_elements = 2 }));
    try testing.expectError(error.TooManyElements, request_decoder.decode(input, testing.allocator, .{ .max_frame_bytes = input.len, .max_elements = 1 }));
    var decoded = (try request_decoder.decode(input ++ input, testing.allocator, .{ .max_frame_bytes = input.len, .max_elements = 2 })).complete;
    defer decoded.deinit(testing.allocator);
    try testing.expectEqual(input.len, decoded.consumed);
}

test "shared decoder releases every allocation on complete and incomplete input" {
    try testing.checkAllAllocationFailures(testing.allocator, decodeWithCleanup, .{false});
    try testing.checkAllAllocationFailures(testing.allocator, decodeWithCleanup, .{true});
}

fn decodeWithCleanup(allocator: std.mem.Allocator, incomplete: bool) !void {
    const input = "*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$5\r\nvalue\r\n";
    const outcome = try request_decoder.decode(if (incomplete) input[0 .. input.len - 1] else input, allocator, request_decoder.aof_limits);
    if (incomplete) {
        try testing.expect(outcome == .incomplete);
    } else {
        var decoded = outcome.complete;
        defer decoded.deinit(allocator);
        try testing.expectEqual(input.len, decoded.consumed);
    }
}
