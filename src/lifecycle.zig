const std = @import("std");

pub const LifecycleHooks = struct {
    context: *anyopaque,
    // Runs after listener and cron startup. An error aborts startup.
    on_ready: ?*const fn (*anyopaque, std.Io.net.IpAddress) anyerror!void = null,
    // Runs once before the initial persistence drain, after cron and workers join.
    on_persistence_draining: ?*const fn (*anyopaque) void = null,

    pub fn notifyReady(self: LifecycleHooks, address: std.Io.net.IpAddress) anyerror!void {
        if (self.on_ready) |callback| try callback(self.context, address);
    }

    pub fn notifyPersistenceDraining(self: LifecycleHooks) void {
        if (self.on_persistence_draining) |callback| callback(self.context);
    }
};
