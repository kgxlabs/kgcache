const std = @import("std");
const Commander = @import("interface.zig");

pub fn parseInt(comptime T: type, argument: []const u8) Commander.Error!T {
    return std.fmt.parseInt(T, argument, 10) catch return error.MalformedCommandRequest;
}
