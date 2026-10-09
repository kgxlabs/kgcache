const std = @import("std");
const testing = std.testing;
const decoder = @import("request_decoder.zig");

const binary_set = "*3\r\n$3\r\nSET\r\n$0\r\n\r\n$5\r\na\x00\r\nb\r\n";
const ping = "*1\r\n$4\r\nPING\r\n";

test "decoder preserves binary arguments and consumes exactly one frame" {
    var input = (binary_set ++ ping).*;
    const limits: decoder.Limits = .{ .max_frame_bytes = binary_set.len, .max_elements = 3 };
    {
        var decoded = (try decoder.decode(&input, testing.allocator, limits)).complete;
        defer decoded.deinit(testing.allocator);

        try testing.expectEqual(binary_set.len, decoded.consumed);
        try testing.expectEqualStrings("SET", decoded.frame.name);
        try testing.expectEqual(2, decoded.frame.arguments.len);
        try testing.expectEqualStrings("", decoded.frame.arguments[0]);
        try testing.expectEqualStrings("a\x00\r\nb", decoded.frame.arguments[1]);
    }
    try testing.expectEqualStrings(binary_set ++ ping, &input);

    var next = (try decoder.decode(input[binary_set.len..], testing.allocator, decoder.network_limits)).complete;
    defer next.deinit(testing.allocator);
    try testing.expectEqualStrings("PING", next.frame.name);
    try testing.expectEqual(ping.len, next.consumed);
}

test "every valid split stays incomplete without allocating" {
    const frames = [_][]const u8{
        ping,
        binary_set,
        "*1\r\n$0\r\n\r\n",
        "*2\r\n$6\r\nSELECT\r\n$2\r\n12\r\n",
        "*2\r\n$4\r\nECHO\r\n$3\r\n\x00\r\n\r\n",
        "*2\r\n$4\r\nECHO\r\n$10\r\n0123\r\n6789\r\n",
        "*10\r\n" ++ ("$0\r\n\r\n" ** 10),
        "*001\r\n$04\r\nPING\r\n",
    };
    for (frames) |frame| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
        for (0..frame.len) |split| {
            const outcome = try decoder.decode(frame[0..split], failing.allocator(), decoder.network_limits);
            try testing.expect(outcome == .incomplete);
            try testing.expect(!failing.has_induced_failure);
        }
        var decoded = (try decoder.decode(frame, testing.allocator, decoder.network_limits)).complete;
        defer decoded.deinit(testing.allocator);
        try testing.expectEqual(frame.len, decoded.consumed);
    }
}

test "non-bulk elements are rejected at every position before allocation" {
    const invalid = [_]struct { bytes: []const u8, err: decoder.DecodeError }{
        .{ .bytes = "$-1\r\n", .err = error.InvalidBulkLength },
        .{ .bytes = "*-1\r\n", .err = error.ExpectedBulkString },
        .{ .bytes = "*0\r\n", .err = error.ExpectedBulkString },
        .{ .bytes = "*1\r\n$5\r\nfruit\r\n", .err = error.ExpectedBulkString },
        .{ .bytes = ":42\r\n", .err = error.ExpectedBulkString },
        .{ .bytes = "+fruit\r\n", .err = error.ExpectedBulkString },
        .{ .bytes = "-ERR\r\n", .err = error.ExpectedBulkString },
    };
    for (invalid) |item| {
        for (0..3) |index| {
            var elements = [_][]const u8{ "$3\r\nDEL\r\n", "$5\r\nfruit\r\n", "$5\r\napple\r\n" };
            elements[index] = item.bytes;
            var buffer: [128]u8 = undefined;
            const input = try std.fmt.bufPrint(&buffer, "*3\r\n{s}{s}{s}", .{ elements[0], elements[1], elements[2] });
            try expectErrorWithoutAllocation(item.err, input, decoder.network_limits);
        }
    }
}

test "known bad headers and terminators never become incomplete" {
    const invalid = [_]struct { bytes: []const u8, err: decoder.DecodeError }{
        .{ .bytes = "PING\r\n", .err = error.ExpectedArray },
        .{ .bytes = "$4\r\nPING\r\n", .err = error.ExpectedArray },
        .{ .bytes = "*0\r", .err = error.EmptyArray },
        .{ .bytes = "*0\r\n", .err = error.EmptyArray },
        .{ .bytes = "*-", .err = error.InvalidArrayLength },
        .{ .bytes = "*-1\r\n", .err = error.InvalidArrayLength },
        .{ .bytes = "*-2\r\n", .err = error.InvalidArrayLength },
        .{ .bytes = "*+1", .err = error.InvalidArrayLength },
        .{ .bytes = "* 1", .err = error.InvalidArrayLength },
        .{ .bytes = "*1_0", .err = error.InvalidArrayLength },
        .{ .bytes = "*0x10", .err = error.InvalidArrayLength },
        .{ .bytes = "*x", .err = error.InvalidArrayLength },
        .{ .bytes = "*\r", .err = error.InvalidArrayLength },
        .{ .bytes = "*1\n", .err = error.InvalidLineEnding },
        .{ .bytes = "*1\rX", .err = error.InvalidLineEnding },
        .{ .bytes = "*1\r\n$-", .err = error.InvalidBulkLength },
        .{ .bytes = "*1\r\n$-1\r\n", .err = error.InvalidBulkLength },
        .{ .bytes = "*1\r\n$-2\r\n", .err = error.InvalidBulkLength },
        .{ .bytes = "*1\r\n$+0", .err = error.InvalidBulkLength },
        .{ .bytes = "*1\r\n$ 0", .err = error.InvalidBulkLength },
        .{ .bytes = "*1\r\n$1_0", .err = error.InvalidBulkLength },
        .{ .bytes = "*1\r\n$0x10", .err = error.InvalidBulkLength },
        .{ .bytes = "*1\r\n$x", .err = error.InvalidBulkLength },
        .{ .bytes = "*1\r\n$\r", .err = error.InvalidBulkLength },
        .{ .bytes = "*1\r\n$0\n", .err = error.InvalidLineEnding },
        .{ .bytes = "*1\r\n$0\rX", .err = error.InvalidLineEnding },
        .{ .bytes = "*1\r\n$1\r\nxX", .err = error.InvalidBulkTerminator },
        .{ .bytes = "*1\r\n$1\r\nx\rX", .err = error.InvalidBulkTerminator },
        .{ .bytes = "*1\r\n$0\r\nX", .err = error.InvalidBulkTerminator },
        .{ .bytes = "*1\r\n*", .err = error.ExpectedBulkString },
        .{ .bytes = "*1\r\n:", .err = error.ExpectedBulkString },
        .{ .bytes = "*1\r\n+", .err = error.ExpectedBulkString },
        .{ .bytes = "*1\r\n-", .err = error.ExpectedBulkString },
    };
    for (invalid) |item| try expectErrorWithoutAllocation(item.err, item.bytes, decoder.aof_limits);
}

test "oversized wire count and length headers fail before allocation" {
    try expectErrorWithoutAllocation(error.LengthOverflow, "*9223372036854775808", decoder.aof_limits);
    try expectErrorWithoutAllocation(error.LengthOverflow, "*1\r\n$9223372036854775808", decoder.aof_limits);
    var buffer: [128]u8 = undefined;
    const maximum = std.math.maxInt(usize);
    const count_overflow = try std.fmt.bufPrint(&buffer, "*{d}0", .{maximum});
    try expectErrorWithoutAllocation(error.LengthOverflow, count_overflow, decoder.aof_limits);
    const length_overflow = try std.fmt.bufPrint(&buffer, "*1\r\n${d}0", .{maximum});
    try expectErrorWithoutAllocation(error.LengthOverflow, length_overflow, decoder.aof_limits);
    if (@bitSizeOf(usize) >= 64) {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
        try testing.expect((try decoder.decode("*1\r\n$9223372036854775807\r\n", failing.allocator(), decoder.aof_limits)) == .incomplete);
        try testing.expect(!failing.has_induced_failure);
    }
}

test "declared limits fail before bodies or argument allocations" {
    try expectErrorWithoutAllocation(error.TooManyElements, "*1025\r\n", decoder.network_limits);
    try expectErrorWithoutAllocation(error.FrameTooLarge, "*1\r\n$1048576\r\n", decoder.network_limits);
    try expectErrorWithoutAllocation(error.FrameTooLarge, "*2\r\n", .{ .max_frame_bytes = 15, .max_elements = 2 });
    try expectErrorWithoutAllocation(error.FrameTooLarge, "*2\r\n$5\r\n", .{ .max_frame_bytes = 20, .max_elements = 2 });
    try expectErrorWithoutAllocation(error.FrameTooLarge, "*00000001", .{ .max_frame_bytes = 8, .max_elements = 1 });
    try expectErrorWithoutAllocation(error.FrameTooLarge, binary_set, .{ .max_frame_bytes = binary_set.len - 1, .max_elements = 3 });
    try expectErrorWithoutAllocation(error.TooManyElements, binary_set, .{ .max_frame_bytes = binary_set.len, .max_elements = 2 });
}

test "AOF limits preserve frames larger than the network profile" {
    const body_len = decoder.network_limits.max_frame_bytes;
    var buffer: [64]u8 = undefined;
    const header = try std.fmt.bufPrint(&buffer, "*2\r\n$4\r\nECHO\r\n${d}\r\n", .{body_len});
    const input = try testing.allocator.alloc(u8, header.len + body_len + 2);
    defer testing.allocator.free(input);
    @memcpy(input[0..header.len], header);
    @memset(input[header.len..][0..body_len], 'x');
    @memcpy(input[input.len - 2 ..], "\r\n");
    try expectErrorWithoutAllocation(error.FrameTooLarge, input, decoder.network_limits);

    var decoded = (try decoder.decode(input, testing.allocator, decoder.aof_limits)).complete;
    defer decoded.deinit(testing.allocator);
    try testing.expectEqual(input.len, decoded.consumed);
    try testing.expectEqual(body_len, decoded.frame.arguments[0].len);
}

test "argument allocation failure preserves input and releases all metadata" {
    var input = binary_set.*;
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, decoder.decode(&input, failing.allocator(), decoder.aof_limits));
    try testing.expectEqualStrings(binary_set, &input);
    try testing.checkAllAllocationFailures(testing.allocator, decodeWithCleanup, .{});
}

fn decodeWithCleanup(allocator: std.mem.Allocator) !void {
    var input = binary_set.*;
    var decoded = (try decoder.decode(&input, allocator, decoder.aof_limits)).complete;
    defer decoded.deinit(allocator);
    try testing.expectEqualStrings(binary_set, &input);
    try testing.expectEqualStrings("a\x00\r\nb", decoded.frame.arguments[1]);
}

fn expectErrorWithoutAllocation(err: decoder.DecodeError, input: []const u8, limits: decoder.Limits) !void {
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(err, decoder.decode(input, failing.allocator(), limits));
    try testing.expect(!failing.has_induced_failure);
}
