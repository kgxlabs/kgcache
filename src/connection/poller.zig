pub const Interface = @import("poller/interface.zig");
pub const EPoller = @import("poller/epoller.zig");
pub const KqueuePoller = @import("poller/kqueuepoller.zig");

// TODO: Implement
pub fn init() !Interface {
    @panic("Poller.init is not implemented");
}

pub fn deinit(_: *Interface) void {
    @panic("poller.deinit is not implemented");
}
