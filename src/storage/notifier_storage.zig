// NOTE: This is a wrapper around real storage backend
// This storage is only responsible for notifying the persistence backends when a operation happens
// There should be no actual storage logic in this file

const std = @import("std");
const persistence = @import("../persistence.zig");
const Storage = @import("interface.zig");
const entry = @import("../entry.zig");
const object = @import("../object.zig");
const time = @import("../time.zig");
const helpers = @import("../helpers.zig");

const NotifierStorage = @This();

_allocator: std.mem.Allocator,
_inner: Storage,
// Currently, we support only one listener (persistence backend) at a time
// unless there is a specific reason user want to have both RDB and AOF
_listener: persistence.FsPersistence,

const vtable: Storage.VTable = .{
    .begin = begin,
    .get = get,
    .put = put,
    .remove = remove,
    .getExp = getExp,
    .setExp = setExp,
    .clearExp = clearExp,
    .removeIfExpired = removeIfExpired,
    .getExpirableCount = getExpirableCount,
    .tryExpireRandom = tryExpireRandom,
    .deinit = deinit,
    .size = size,
};

pub fn storage(self: *NotifierStorage) Storage {
    return .{
        .ptr = self,
        .vtable = &vtable,
        ._io = self._inner._io,
        ._mutex = self._inner._mutex,
    };
}

pub fn init(
    allocator: std.mem.Allocator,
    inner: Storage,
    listener: persistence.FsPersistence,
) NotifierStorage {
    return .{
        ._allocator = allocator,
        ._inner = inner,
        ._listener = listener,
    };
}

pub fn begin(ptr: *anyopaque) Storage.Error!Storage.Tx {
    var self: *NotifierStorage = @ptrCast(@alignCast(ptr));
    return self._inner.begin();
}

// TODO: Figure out do we need to clean up our own or not here
pub fn deinit(ptr: *anyopaque) void {
    const self: *NotifierStorage = @ptrCast(@alignCast(ptr));
    return self._inner.deinit();
}

pub fn get(ptr: *anyopaque, key: []const u8) Storage.Error!?entry.Object {
    const self: *NotifierStorage = @ptrCast(@alignCast(ptr));
    // NOTE: `get` can silently remove `key` as a side effect (lazy expiration,
    // below), but that removal is not observable without coupling with the persistence layer
    // So instead of relying on concrete storage get removal, we are doing that operation in advance
    // so when concrete `get` checks for removal it will already be removed
    const is_removed = try self._inner.removeIfExpired(key);

    if (is_removed) {
        try self._listener.onWrite(.{
            .remove = .{ .key = key },
        });
    }

    return self._inner.get(key);
}

pub fn put(ptr: *anyopaque, key: []const u8, value: object.Object, options: Storage.PutOptions) Storage.Error!entry.Object {
    const self: *NotifierStorage = @ptrCast(@alignCast(ptr));
    const result = self._inner.put(key, value, options);

    try self._listener.onWrite(.{ .put = .{
        .key = key,
        .value = value,
        .options = options,
    } });

    return result;
}

pub fn remove(ptr: *anyopaque, key: []const u8) Storage.Error!void {
    const self: *NotifierStorage = @ptrCast(@alignCast(ptr));
    return self._inner.remove(key);
}

pub fn removeIfExpired(ptr: *anyopaque, key: []const u8) Storage.Error!bool {
    const self: *NotifierStorage = @ptrCast(@alignCast(ptr));
    return self._inner.removeIfExpired(key);
}

pub fn getExp(ptr: *anyopaque, key: []const u8) Storage.Error!?entry.ObjectExpiration {
    const self: *NotifierStorage = @ptrCast(@alignCast(ptr));
    return self._inner.getExp(key);
}

pub fn setExp(ptr: *anyopaque, key: []const u8, exp: ?time.UnixMs) Storage.Error!entry.ObjectExpiration {
    const self: *NotifierStorage = @ptrCast(@alignCast(ptr));
    return self._inner.setExp(key, exp);
}

pub fn tryExpireRandom(ptr: *anyopaque) Storage.Error!?[]const u8 {
    const self: *NotifierStorage = @ptrCast(@alignCast(ptr));
    return self._inner.tryExpireRandom();
}

pub fn getExpirableCount(ptr: *anyopaque) u32 {
    const self: *NotifierStorage = @ptrCast(@alignCast(ptr));
    return self._inner.getExpirableCount();
}

pub fn clearExp(ptr: *anyopaque, key: []const u8) Storage.Error!void {
    const self: *NotifierStorage = @ptrCast(@alignCast(ptr));
    return self._inner.clearExp(key);
}

pub fn size(ptr: *anyopaque) u32 {
    const self: *NotifierStorage = @ptrCast(@alignCast(ptr));
    return self._inner.size();
}
