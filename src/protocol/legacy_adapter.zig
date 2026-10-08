const std = @import("std");
const legacy = @import("../resp.zig");
const CommandFrame = @import("command_frame.zig");
const request_decoder = @import("request_decoder.zig");
const Resp = @import("interface.zig");

pub const ReplyError = std.mem.Allocator.Error || Resp.EncodeError;

pub fn decode(input: []const u8, allocator: std.mem.Allocator, limits: request_decoder.Limits) request_decoder.DecodeError!request_decoder.DecodeResult {
    if (input.len == 0) return .incomplete;
    if (input[0] != '*') return error.ExpectedArray;
    const parsed = legacy.parseValue(allocator, input) catch |err| switch (err) {
        error.Incomplete => return .incomplete,
        error.OutOfMemory => return error.OutOfMemory,
        error.MalformedSize, error.NotInteger => return error.InvalidBulkLength,
        error.InvalidType => return error.ExpectedBulkString,
        error.IncorrectToken, error.Malformed, error.ExceededSize => return error.InvalidBulkTerminator,
    };
    defer legacy.freeValue(allocator, parsed.value);
    if (parsed.consumed > limits.max_frame_bytes) return error.FrameTooLarge;
    if (parsed.value.array) |items| {
        if (items.len > limits.max_elements) return error.TooManyElements;
    }
    return .{ .complete = .{
        .frame = try commandFrame(allocator, parsed.value),
        .consumed = parsed.consumed,
    } };
}

pub fn writeCommand(writer: *std.Io.Writer, frame: CommandFrame) @import("resp_command_encoder.zig").CommandEncodeError!void {
    const count = std.math.add(usize, frame.arguments.len, 1) catch return error.LengthOverflow;
    if (std.math.cast(i64, count) == null or std.math.cast(i64, frame.name.len) == null) return error.LengthOverflow;
    for (frame.arguments) |argument| {
        if (std.math.cast(i64, argument.len) == null) return error.LengthOverflow;
    }
    try writer.print("*{d}\r\n", .{count});
    try writeBulk(writer, frame.name);
    for (frame.arguments) |argument| try writeBulk(writer, argument);
}

fn writeBulk(writer: *std.Io.Writer, bytes: []const u8) std.Io.Writer.Error!void {
    try writer.print("${d}\r\n", .{bytes.len});
    try writer.writeAll(bytes);
    try writer.writeAll("\r\n");
}

pub fn commandFrame(allocator: std.mem.Allocator, value: legacy.RESPValue) request_decoder.DecodeError!CommandFrame {
    const items = switch (value) {
        .array => |maybe_items| maybe_items orelse return error.InvalidArrayLength,
        else => return error.ExpectedArray,
    };
    if (items.len == 0) return error.EmptyArray;

    for (items) |item| {
        switch (item) {
            .bulk_string => |bytes| if (bytes == null) return error.InvalidBulkLength,
            else => return error.ExpectedBulkString,
        }
    }

    const arguments = try allocator.alloc([]const u8, items.len - 1);
    for (items[1..], arguments) |item, *argument| argument.* = item.bulk_string.?;

    return .{ .name = items[0].bulk_string.?, .arguments = arguments };
}

pub fn writeReply(
    allocator: std.mem.Allocator,
    selected: Resp,
    writer: *std.Io.Writer,
    value: legacy.RESPValue,
) ReplyError!void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const reply = try convertReply(arena.allocator(), value);
    try selected.writeReply(writer, reply);
    try writer.flush();
}

fn convertReply(allocator: std.mem.Allocator, value: legacy.RESPValue) std.mem.Allocator.Error!Resp.Reply {
    return switch (value) {
        .simple_string => |text| .{ .simple_string = text },
        .simple_error => |text| .{ .error_reply = text },
        .integer => |number| .{ .integer = number },
        .bulk_string => |maybe_bytes| if (maybe_bytes) |bytes| .{ .blob_string = bytes } else .{ .null_value = .bulk_string },
        .array => |maybe_items| if (maybe_items) |items| blk: {
            const replies = try allocator.alloc(Resp.Reply, items.len);
            for (items, replies) |item, *reply| reply.* = try convertReply(allocator, item);
            break :blk .{ .array = replies };
        } else .{ .null_value = .array },
    };
}
