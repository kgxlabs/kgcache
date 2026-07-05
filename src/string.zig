const std = @import("std");

pub fn lowercaseAlloc(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    return std.ascii.allocLowerString(allocator, input);
}
