const std = @import("std");
const Poller = @import("interface.zig");

const KqueuePoller = @This();

pub fn init() !KqueuePoller {
    return .{};
}

pub fn deinit(ptr: *anyopaque) void {
    const self: *KqueuePoller = @ptrCast(@alignCast(ptr));
}

pub fn poller(self: *KqueuePoller) Poller {
    return .{
        .ptr = self,
        .vtable = &vtable,
    };
}

const vtable = Poller.VTable{};
