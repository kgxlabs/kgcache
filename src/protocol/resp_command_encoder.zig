const std = @import("std");
const CommandFrame = @import("command_frame.zig");

pub const CommandEncodeError = std.Io.Writer.Error || error{LengthOverflow};

pub const WriteCommandFn = *const fn (
    writer: *std.Io.Writer,
    frame: CommandFrame,
) CommandEncodeError!void;

pub fn writeCommand(writer: *std.Io.Writer, frame: CommandFrame) CommandEncodeError!void {
    return @import("legacy_adapter.zig").writeCommand(writer, frame);
}
