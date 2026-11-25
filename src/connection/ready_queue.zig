const std = @import("std");
const ClientSession = @import("session.zig");

const ReadyQueue = @This();

pub const Turn = struct {
    session: *ClientSession,
    ready_since_ns: std.Io.Timestamp,
    signals: ClientSession.ReadySignals,
};

_head: ?*ClientSession = null,
_tail: ?*ClientSession = null,

// Worker-only. Merge duplicates and preserve the original queued timestamp.
pub fn push(self: *ReadyQueue, session: *ClientSession, signals: ClientSession.ReadySignals, now_ns: std.Io.Timestamp) void {
    _ = .{ self, session, signals, now_ns };
    @panic("ReadyQueue.push is not implemented");
}

// Unlink and capture signals before service. A later turn gets a new timestamp.
pub fn pop(self: *ReadyQueue) ?Turn {
    _ = self;
    @panic("ReadyQueue.pop is not implemented");
}

pub fn remove(self: *ReadyQueue, session: *ClientSession) void {
    _ = .{ self, session };
    @panic("ReadyQueue.remove is not implemented");
}

pub fn oldestTimestamp(self: *const ReadyQueue) ?std.Io.Timestamp {
    _ = self;
    @panic("ReadyQueue.oldestTimestamp is not implemented");
}

pub fn isEmpty(self: *const ReadyQueue) bool {
    return self._head == null;
}
