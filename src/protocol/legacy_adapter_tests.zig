const std = @import("std");
const testing = std.testing;
const legacy = @import("../resp.zig");
const adapter = @import("legacy_adapter.zig");
const Resp2 = @import("resp2.zig");
const Resp3 = @import("resp3.zig");
const Commander = @import("../commander/interface.zig");
const object = @import("../object.zig");

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
