const std = @import("std");
const legacy = @import("../resp.zig");
const CommandFrame = @import("command_frame.zig");
const Resp = @import("interface.zig");

pub const ReplyError = std.mem.Allocator.Error || Resp.EncodeError;

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
