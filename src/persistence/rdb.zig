const std = @import("std");
const time = @import("../time.zig");
const Persistence = @import("./interface.zig");

const RdbBackend = @This();

_io: std.Io,
_dirty: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
_last_save_at: time.UnixMs,

const vtable: Persistence.VTable = .{
    .onWrite = onWrite,
};

pub fn init(io: std.Io) RdbBackend {
    return .{
        ._io = io,
        ._last_save_at = time.nowMs(io),
    };
}

pub fn persistence(self: *RdbBackend) Persistence {
    return .{
        .ptr = self,
        .vtable = &vtable,
    };
}

// This is just a stub method since rdb does not really need to track everytime write operation happens
pub fn onWrite(_: *anyopaque, _: Persistence.WriteEvent) Persistence.Error!void {
    return;
}
