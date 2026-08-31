const std = @import("std");

pub fn eqlStringIgnoreCase(value: []const u8, expected: []const u8) bool {
    return std.ascii.eqlIgnoreCase(value, expected);
}

pub fn isEpochS(value: i64) bool {
    // Unix seconds between 2000 and 2100
    return value >= 946684800 and value <= 4102444800;
}

pub fn isEpochMs(value: i64) bool {
    // Unix milli seconds between 2000 and 2100
    return value >= 946684800000 and value <= 4102444800000;
}

pub fn random(io: std.Io, min: usize, max: usize) usize {
    var io_rand_source: std.Random.IoSource = .{ .io = io };
    const rand = io_rand_source.interface();

    return rand.intRangeAtMost(usize, min, max);
}

pub fn fileExists(io: std.Io, dir: std.Io.Dir, path: []const u8) !bool {
    dir.access(io, path, .{}) catch |err| {
        switch (err) {
            // This error explicitly confirms the file is missing
            error.FileNotFound => return false,
            // Forward any other critical errors (e.g., AccessDenied)
            else => return err,
        }
    };
    return true;
}

pub fn logStdout(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const message = std.fmt.bufPrint(&buf, fmt, args) catch fmt;
    std.Io.File.writeStreamingAll(std.Io.File.stdout(), io, message) catch {};
}

pub fn logStderr(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const message = std.fmt.bufPrint(&buf, fmt, args) catch fmt;
    std.Io.File.writeStreamingAll(std.Io.File.stderr(), io, message) catch {};
}
