const std = @import("std");
const Poller = @import("interface.zig");

const EPoller = @This();

pub fn init() !EPoller {
    return .{};
}

pub fn deinit(_: *anyopaque) void {
    @panic("EPoller.deinit is not implemented");
}

pub fn poller(self: *EPoller) Poller {
    return .{
        .ptr = self,
        .vtable = &vtable,
    };
}

const vtable = Poller.VTable{};
