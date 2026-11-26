const std = @import("std");
const Poller = @import("interface.zig");

const KqueuePoller = @This();

pub fn init() !KqueuePoller {
    return .{};
}

pub fn deinit(_: *anyopaque) void {
    @panic("KqueuePoller.deinit is not implemented");
}

pub fn poller(self: *KqueuePoller) Poller {
    return .{
        .ptr = self,
        .vtable = &vtable,
    };
}

const vtable = Poller.VTable{};
