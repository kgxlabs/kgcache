const std = @import("std");
const Config = @import("../config.zig");

pub fn loadFromPath(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: ?[]const u8,
) anyerror!Config {
    _ = io;
    _ = allocator;
    _ = path;
    @panic("config loader is not implemented");
}

test {
    std.testing.refAllDecls(@This());
}
