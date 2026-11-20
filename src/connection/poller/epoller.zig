const std = @import("std");
const Poller = @import("interface.zig");

const EPoller = @This();

pub fn init() !EPoller {
    return .{};
}

pub fn deinit(ptr: *anyopaque) void {
    const self: *EPoller = @ptrCast(@alignCast(ptr));
}

pub fn poller(self: *EPoller) Poller {
    return .{
        .ptr = self,
        .vtable = &vtable,
    };
}

const vtable = Poller.VTable{};
