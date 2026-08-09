const std = @import("std");
const Journal = @import("./journal_interface.zig");
const AofEncoder = @import("../codec/aof_encoder.zig");

const AofBackend = @This();

_allocator: std.mem.Allocator,
_encoder: AofEncoder,

const vtable: Journal.VTable = .{
    .onWrite = onWrite,
};

pub fn init(allocator: std.mem.Allocator) AofBackend {
    return .{
        ._allocator = allocator,
        ._encoder = AofEncoder.init(),
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
