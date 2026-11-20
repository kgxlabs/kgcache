pub const Poller = @import("poller/interface.zig");
pub const EPoller = @import("poller/epoller.zig");
pub const KqueuePoller = @import("poller/kqueuepoller.zig");

pub fn init() !Poller {
    @panic("poller.init is not implemented");
}

pub fn deinit(_: *Poller) void {
    @panic("poller.deinit is not implemented");
}
