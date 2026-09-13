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
    const event = self.nextEvent() orelse return;
    event.* = .{
        .kind = .log,
        .level = level,
    };

    event.message_len = @min(message.len, max_message_len);
    @memcpy(event.message_buffer[0..event.message_len], message[0..event.message_len]);
}

fn err(ptr: *anyopaque, source: anyerror, trace: Logger.ErrorTrace) void {
    const self: *TestLogger = @ptrCast(@alignCast(ptr));
    const event = self.nextEvent() orelse return;
    event.* = .{
        .kind = .err,
        .source = source,
        .has_trace = trace != null,
        .trace_frame_count = if (trace) |return_trace|
            @min(return_trace.index, return_trace.instruction_addresses.len)
        else
            0,
    };
}

fn nextEvent(self: *TestLogger) ?*Event {
    if (self.event_count == max_events) {
        self.dropped_event_count +|= 1;
        return null;
    }

    const event = &self.events[self.event_count];
    self.event_count += 1;
    return event;
}

// No tests are added unless we need them in the future.
