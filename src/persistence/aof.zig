const std = @import("std");
const Journal = @import("./journal_interface.zig");
const AofEncoder = @import("../codec/aof_encoder.zig");
const PersistenceState = @import("../persistence_state.zig");

const AofBackend = @This();

_allocator: std.mem.Allocator,
_encoder: AofEncoder,
_persistence_state: *PersistenceState,

const vtable: Journal.VTable = .{
    .bgRewrite = bgRewrite,
    .close = close,
    .finishRewrite = finishRewrite,
    .flush = flush,
    .onWrite = onWrite,
};

pub fn init(allocator: std.mem.Allocator, state: *PersistenceState) AofBackend {
    return .{
        ._allocator = allocator,
        ._encoder = AofEncoder.init(),
        ._persistence_state = state,
    };
}

pub fn journal(self: *AofBackend) Journal {
    return .{
        .ptr = self,
        .vtable = &vtable,
    };
}

pub fn onWrite(ptr: *anyopaque, event: Journal.WriteEvent) Journal.Error!void {
    const self: *AofBackend = @ptrCast(@alignCast(ptr));

    const encoded = self._encoder.encode(self._allocator, event) catch return Journal.Error.OutOfMemory;
    defer self._encoder.deinit(self._allocator, encoded);

    // TODO: append `encoded` to the AOF file on disk. Needs its own design
    // pass (append-mode file handle, buffering/fsync policy) — out of scope
    // for wiring up the encoder itself.
}

pub fn bgRewrite(_: *anyopaque) Journal.Error!void {
    return;
}

pub fn finishRewrite(_: *anyopaque, _: bool) Journal.Error!void {
    return;
}

pub fn flush(_: *anyopaque, _: i64) Journal.Error!void {
    return;
}

pub fn close(_: *anyopaque) Journal.Error!void {
    return;
}
