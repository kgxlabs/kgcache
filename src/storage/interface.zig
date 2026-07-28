const std = @import("std");
const entry = @import("../entry.zig");
const object = @import("../object.zig");
const time = @import("../time.zig");

pub const Error = error{
    OutOfMemory,
    InvalidIndex,
    UnableToExpire,
};

const Storage = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const PutOptions = struct {
    expires_at: ?time.UnixMs,
    keepttl: bool = false,
};

pub const RemovalMode = enum {
    expired_only,
    unconditional,
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
    getExpCount: *const fn (*anyopaque) Error!usize,
    clearExp: *const fn (*anyopaque, []const u8) Error!void,
    deinit: *const fn (*anyopaque) void,
};

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
    return self.vtable.remove(self.ptr, key);
}

pub fn getExp(self: Storage, key: []const u8) Error!?entry.ObjectExpiration {
    return self.vtable.getExp(self.ptr, key);
}

pub fn setExp(self: Storage, key: []const u8, expires_at: ?time.UnixMs) Error!entry.ObjectExpiration {
    return self.vtable.setExp(self.ptr, key, expires_at);
}

pub fn getExpCount(self: Storage) Error!?usize {
    return self.vtable.getExpCount(self.ptr);
}

pub fn clearExp(self: Storage, key: []const u8) Error!void {
    return self.vtable.clearExp(self.ptr, key);
}

pub fn deinit(self: Storage) void {
    self.vtable.deinit(self.ptr);
}
