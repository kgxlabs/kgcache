const Logger = @import("interface.zig");

const TestLogger = @This();

pub const max_events = 64;
pub const max_message_len = 256;

pub const Event = struct {
    kind: Kind,
    level: ?Logger.Level = null,
    source: ?anyerror = null,
    has_trace: bool = false,
    trace_frame_count: usize = 0,
    message_buffer: [max_message_len]u8 = undefined,
    message_len: usize = 0,

    pub const Kind = enum {
        log,
        err,
    };

    pub fn message(self: *const Event) []const u8 {
        return self.message_buffer[0..self.message_len];
    }
};

events: [max_events]Event = undefined,
event_count: usize = 0,
dropped_event_count: usize = 0,

pub fn init() TestLogger {
    return .{};
}

pub fn logger(self: *TestLogger) Logger {
    return .{
        .ptr = self,
        .vtable = &vtable,
    };
}

pub fn recordedEvents(self: *const TestLogger) []const Event {
    return self.events[0..self.event_count];
}

pub fn reset(self: *TestLogger) void {
    self.event_count = 0;
    self.dropped_event_count = 0;
}

const vtable: Logger.VTable = .{
    .log = log,
    .err = err,
};

fn log(ptr: *anyopaque, level: Logger.Level, message: []const u8) void {
    const self: *TestLogger = @ptrCast(@alignCast(ptr));
    _ = self;
    _ = level;
    _ = message;
}

fn err(ptr: *anyopaque, source: anyerror, trace: Logger.ErrorTrace) void {
    const self: *TestLogger = @ptrCast(@alignCast(ptr));
    _ = self;
    _ = source;
    _ = trace;
}

// No tests are added unless we need them in the future.
