const std = @import("std");
const entry = @import("../entry.zig");
const object = @import("../object.zig");
const time = @import("../time.zig");

pub const Error = error{
    OutOfMemory,
};

const Storage = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    get: *const fn (*anyopaque, []const u8) Error!?entry.Object,
    put: *const fn (*anyopaque, []const u8, object.Object, ?time.UnixMs) Error!entry.Object,
    remove: *const fn (*anyopaque, []const u8) Error!void,
    getExp: *const fn (*anyopaque, []const u8) Error!?entry.ObjectExpiration,
    setExp: *const fn (*anyopaque, []const u8, ?time.UnixMs) Error!entry.ObjectExpiration,
    clearExp: *const fn (*anyopaque, []const u8) Error!void,
    deinit: *const fn (*anyopaque) void,
};

pub fn get(self: Storage, key: []const u8) Error!?entry.Object {
    return self.vtable.get(self.ptr, key);
}

pub fn put(self: Storage, key: []const u8, entry_object: object.Object, expires_at: ?time.UnixMs) Error!entry.Object {
    return self.vtable.put(self.ptr, key, entry_object, expires_at);
}

pub fn remove(self: Storage, key: []const u8) Error!void {
    return self.vtable.remove(self.ptr, key);
}

pub fn getExp(self: Storage, key: []const u8) Error!?entry.ObjectExpiration {
    return self.vtable.getExp(self.ptr, key);
}

pub fn setExp(self: Storage, key: []const u8, expires_at: ?time.UnixMs) Error!entry.ObjectExpiration {
    return self.vtable.setExp(self.ptr, key, expires_at);
}

pub fn clearExp(self: Storage, key: []const u8) Error!void {
    return self.vtable.clearExp(self.ptr, key);
}

pub fn deinit(self: Storage) void {
    self.vtable.deinit(self.ptr);
}
