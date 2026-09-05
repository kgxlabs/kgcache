const std = @import("std");
const entry = @import("../entry.zig");
const object = @import("../object.zig");
const time = @import("../time.zig");

pub const Error = error{
    OutOfMemory,
    InvalidIndex,
    UnableToExpire,
    TxCancelled,
    UnableToRecordWrite,
};

const Storage = @This();

ptr: *anyopaque,
vtable: *const VTable,
_io: std.Io,
_mutex: *std.Io.Mutex,

pub const PutOptions = struct {
    expires_at: ?time.UnixMs,
    keepttl: bool = false,
};

pub const RemovalMode = enum {
    expired_only,
    unconditional,
};

pub const Tx = struct {
    _io: std.Io,
    _mutex: *std.Io.Mutex,

    pub fn end(self: *Tx) void {
        return self._mutex.unlock(self._io);
    }
};

pub const VTable = struct {
    get: *const fn (*anyopaque, []const u8) Error!?entry.Object,
    put: *const fn (*anyopaque, []const u8, object.Object, PutOptions) Error!entry.Object,
    // NOTE: remove and removeIfExpired are basically the same.
    // Only difference is intent. The reason we split two functions is
    // because we want to have a bool return for `removeIfExpired` so that the client can utilize that to make subsequent decision
    // and we dont want to pollute `remove`.
    // TODO: Refactor this if we find a better solution
    remove: *const fn (*anyopaque, []const u8) Error!void,
    removeIfExpired: *const fn (*anyopaque, []const u8) Error!bool,
    getExp: *const fn (*anyopaque, []const u8) Error!?entry.ObjectExpiration,
    setExp: *const fn (*anyopaque, []const u8, ?time.UnixMs) Error!entry.ObjectExpiration,
    getExpirableCount: *const fn (*anyopaque) u32,
    // Returns the key that was expired and removed, or `null` if nothing was
    // removed. The returned slice is a fresh allocation owned by the caller;
    // the caller must free it (see `tryExpireRandom` below).
    tryExpireRandom: *const fn (*anyopaque) Error!?[]const u8,
    clearExp: *const fn (*anyopaque, []const u8) Error!void,
    size: *const fn (*anyopaque) u32,
    begin: *const fn (*anyopaque) Error!Tx,
    forEach: *const fn (
        *anyopaque,
        *anyopaque,
        *const fn (*anyopaque, []const u8, object.Object, ?time.UnixMs) anyerror!void,
    ) Error!void,
    deinit: *const fn (*anyopaque) void,
};

pub fn begin(self: Storage) Error!Tx {
    return self.vtable.begin(self.ptr);
}

pub fn get(self: Storage, key: []const u8) Error!?entry.Object {
    return self.vtable.get(self.ptr, key);
}

pub fn put(self: Storage, key: []const u8, entry_object: object.Object, options: PutOptions) Error!entry.Object {
    return self.vtable.put(self.ptr, key, entry_object, options);
}

pub fn remove(self: Storage, key: []const u8) Error!void {
    return self.vtable.remove(self.ptr, key);
}

pub fn removeIfExpired(self: Storage, key: []const u8) Error!bool {
    return self.vtable.removeIfExpired(self.ptr, key);
}

pub fn getExp(self: Storage, key: []const u8) Error!?entry.ObjectExpiration {
    return self.vtable.getExp(self.ptr, key);
}

pub fn setExp(self: Storage, key: []const u8, expires_at: ?time.UnixMs) Error!entry.ObjectExpiration {
    return self.vtable.setExp(self.ptr, key, expires_at);
}

pub fn getExpirableCount(self: Storage) u32 {
    return self.vtable.getExpirableCount(self.ptr);
}

/// Expires and removes one random expirable key, if any exist.
/// Returns the removed key, or `null` if nothing was removed.
/// The caller must free the returned key with the same allocator the
/// storage implementation was created with.
pub fn tryExpireRandom(self: Storage) Error!?[]const u8 {
    return self.vtable.tryExpireRandom(self.ptr);
}

pub fn clearExp(self: Storage, key: []const u8) Error!void {
    return self.vtable.clearExp(self.ptr, key);
}

pub fn forEach(self: Storage, ctx: *anyopaque, visit: *const fn (ctx: *anyopaque, key: []const u8, value: object.Object, exp: ?time.UnixMs) anyerror!void) Error!void {
    return self.vtable.forEach(self.ptr, ctx, visit);
}

pub fn size(self: Storage) u32 {
    return self.vtable.size(self.ptr);
}

pub fn deinit(self: Storage) void {
    self.vtable.deinit(self.ptr);
}
