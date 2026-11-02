const std = @import("std");

// Optional callbacks in the parent. Callers compose actions in adapters.
pub const LifecycleHooks = struct {
    // Borrowed through run and destroy. Retain with an unresolved Server.
    context: *anyopaque,
    // After bind and cron startup. Source errors fail run unchanged.
    on_ready: ?*const fn (*anyopaque, std.Io.net.IpAddress) anyerror!void = null,
    // Once per destroy, after cron and workers join, before the initial drain.
    // Includes empty drains. Uses the shared deadline. Cannot veto cleanup.
    on_persistence_draining: ?*const fn (*anyopaque) void = null,

    pub fn notifyReady(self: LifecycleHooks, address: std.Io.net.IpAddress) anyerror!void {
        if (self.on_ready) |callback| try callback(self.context, address);
    }

    pub fn notifyPersistenceDraining(self: LifecycleHooks) void {
        if (self.on_persistence_draining) |callback| callback(self.context);
    }
};
