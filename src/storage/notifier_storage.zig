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
_listeners: []persistence.PListener,

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
        ._io = self._io,
        ._mutex = &self._mutex,
    };
}

pub fn init(
    allocator: std.mem.Allocator,
    inner: Storage,
    listeners: []persistence.PListener,
) NotifierStorage {
    return .{
        ._allocator = allocator,
        ._inner = inner,
        ._listeners = listeners,
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
    return self._inner.get(key);
}

pub fn put(ptr: *anyopaque, key: []const u8, value: object.Object, options: Storage.PutOptions) Storage.Error!entry.Object {
    const self: *NotifierStorage = @ptrCast(@alignCast(ptr));
    return self._inner.put(key, value, options);
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
    return @intCast(self._entry_map.count());
}
