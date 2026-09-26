const std = @import("std");

pub fn withScratchDir(comptime name: []const u8, comptime testFn: fn (std.Io, std.Io.Dir) anyerror!void) !void {
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    cwd.deleteTree(io, name) catch {};
    defer cwd.deleteTree(io, name) catch {};

    try cwd.createDir(io, name, .default_dir);
    var dir = try cwd.openDir(io, name, .{ .iterate = true });
    defer dir.close(io);

    try testFn(io, dir);
}
