const Logger = @import("interface.zig");

const NoopLogger = @This();

var instance: NoopLogger = .{};

pub fn logger() Logger {
    return .{
        .ptr = &instance,
        .vtable = &vtable,
    };
}

const vtable: Logger.VTable = .{
    .log = log,
    .err = err,
};

fn log(_: *anyopaque, _: Logger.Level, _: []const u8) void {}

fn err(_: *anyopaque, _: []const u8, _: anyerror, _: Logger.ErrorTrace) void {}
