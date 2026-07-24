const std = @import("std");

pub fn eqlStringIgnoreCase(value: []const u8, expected: []const u8) bool {
    return std.ascii.eqlIgnoreCase(value, expected);
}
