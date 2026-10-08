const std = @import("std");
const CommandFrame = @import("command_frame.zig");

pub const CommandEncodeError = std.Io.Writer.Error || error{LengthOverflow};

pub const WriteCommandFn = *const fn (
    writer: *std.Io.Writer,
    frame: CommandFrame,
) CommandEncodeError!void;

pub fn writeCommand(writer: *std.Io.Writer, frame: CommandFrame) CommandEncodeError!void {
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
