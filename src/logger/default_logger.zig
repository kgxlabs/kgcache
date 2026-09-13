const std = @import("std");
const Logger = @import("interface.zig");

const DefaultLogger = @This();

_io: std.Io,

pub fn init(io: std.Io) DefaultLogger {
    return .{ ._io = io };
}

pub fn logger(self: *DefaultLogger) Logger {
    return .{
        .ptr = self,
        .vtable = &vtable,
    };
}

const vtable: Logger.VTable = .{
    .log = log,
    .err = err,
};

fn log(ptr: *anyopaque, level: Logger.Level, message: []const u8) void {
    const self: *DefaultLogger = @ptrCast(@alignCast(ptr));
    _ = self;
    _ = level;
    _ = message;
}

fn err(ptr: *anyopaque, source: anyerror, trace: Logger.ErrorTrace) void {
    const self: *DefaultLogger = @ptrCast(@alignCast(ptr));
    _ = self;
    _ = source;
    _ = trace;
}
