const builtint = @import("builtin");
pub const Interface = @import("poller/interface.zig");
pub const EPoller = @import("poller/epoller.zig");
pub const KqueuePoller = @import("poller/kqueuepoller.zig");

// TODO: Implement
pub fn init() !Interface {
    switch (builtint.os.tag) {
        .linux => {
            return EPoller.init();
        },
        .macos => {
            return KqueuePoller.init();
        },
    }

    @panic("poller.init is not implemented");
}

pub fn deinit(_: *Interface) void {
    @panic("poller.deinit is not implemented");
}
