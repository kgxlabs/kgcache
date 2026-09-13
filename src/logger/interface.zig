const std = @import("std");

const Logger = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const Level = enum {
    debug,
    info,
    warn,
};

pub const ErrorTrace = ?*const std.builtin.StackTrace;

pub const VTable = struct {
    log: *const fn (*anyopaque, Level, []const u8) void,
    err: *const fn (*anyopaque, anyerror, ErrorTrace) void,
};

pub fn log(self: Logger, level: Level, message: []const u8) void {
    self.vtable.log(self.ptr, level, message);
}

pub fn debug(self: Logger, message: []const u8) void {
    self.log(.debug, message);
}

pub fn info(self: Logger, message: []const u8) void {
    self.log(.info, message);
}

pub fn warn(self: Logger, message: []const u8) void {
    self.log(.warn, message);
}

// Error traces show the return path, not whether an operation partially succeeded.
/// Sinks must consume the trace during this call and must not retain its pointer.
pub fn err(self: Logger, source: anyerror, trace: ErrorTrace) void {
    self.vtable.err(self.ptr, source, trace);
}
