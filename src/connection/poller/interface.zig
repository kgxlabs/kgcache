const std = @import("std");
const time = @import("../../time.zig");
const ClientSession = @import("../session.zig");

const Poller = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const Interests = struct {
    read: bool,
    write: bool,
};

pub const EventBuffer = [64]Event;
pub const Event = union(enum) {
    wakeup,
    socket_ready: SocketReady,

    pub const SocketReady = struct {
        token: u64,
        readable: bool = false,
        writable: bool = false,
        // The read side reported closure. Buffered data may still remain.
        read_closed: bool = false,
        // The socket reported an error that needs handling.
        has_error: bool = false,
    };
};

pub const VTable = struct {
    add: *const fn (*anyopaque, std.Io.net.Stream, ClientSession.SessionId, Interests) anyerror!void,
    modify: *const fn (*anyopaque, std.Io.net.Stream, Interests) anyerror!void,
    remove: *const fn (*anyopaque, std.Io.net.Stream) anyerror!void,
    // timeout: 0 = Check now and return immediately, 1000 = Wait up to one second. Return sooner if event arrives , null = Wait indefinitely until an event arrives
    // NOTE: The array has room for 64 event records. The poller does not need to wait until all 64 slots are filled.
    // If count is 3, only these entries contain returned results: events[0], events[1], events[2]
    // Those results might mean: Session 9001 can be read. Session 9002 can be written. A Wakeup notification arrived.
    wait: *const fn (*anyopaque, *EventBuffer, ?time.DurationMs) anyerror!void,
    // NOTE: If the worker is waiting, the notification makes its wait return.
    // If the notification arrives before it starts waiting, the notification must remain pending until consumed.
    // On Linux, wake() writes 1 to the internal eventfd.
    // On macOS, wake() triggers the internal user event.
    wake: *const fn (*anyopaque) anyerror!usize,
    // On Linux, it closes the internal epoll and eventfd resources. On macOS, it closes the kqueue.
    // But it won't close the client sockets
    deinit: *const fn (*anyopaque) void,
};

pub fn add(self: *Poller, socket: std.Io.net.Stream, token: ClientSession.SessionId, interests: Interests) !void {
    return self.vtable.add(self.ptr, socket, token, interests);
}

pub fn modify(self: *Poller, socket: std.Io.net.Stream, interests: Interests) !void {
    return self.vtable.modify(self.ptr, socket, interests);
}

pub fn remove(self: *Poller, socket: std.Io.net.Stream) !void {
    return self.vtable.remove(self.ptr, socket);
}

pub fn wait(self: *Poller, event_buffer: *EventBuffer, timeout: ?time.DurationMs) !void {
    return self.vtable.wait(self.ptr, event_buffer, timeout);
}

pub fn wake(self: *Poller) !usize {
    return self.vtable.wake(self.ptr);
}

pub fn deinit(self: *Poller) void {
    self.vtable.deinit(self.ptr);
}
