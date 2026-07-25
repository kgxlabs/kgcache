const std = @import("std");
const entry = @import("../entry.zig");
const object = @import("../object.zig");

pub const Error = error{};

const Storage = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    get: *const fn (*anyopaque, []const u8) Error!?entry.Object,
    put: *const fn (*anyopaque, []const u8, object.Object, ?entry.ObjectExpirationMs) Error!?entry.Object,
    remove: *const fn (*anyopaque, []const u8) Error!void,
    getExp: *const fn (*anyopaque, []const u8) Error!?entry.ObjectExpiration,
    setExp: *const fn (*anyopaque, []const u8, entry.ObjectExpiration) Error!entry.ObjectExpiration,
    clearExp: *const fn (*anyopaque, []const u8) Error!void,
    deinit: *const fn (*anyopaque) void,
};

pub fn get(self: Storage, key: []const u8) Error!?entry.Object {
    return self.vtable.get(self.ptr, key);
}

pub fn put(self: Storage, key: []const u8, entry_object: object.Object, exp_ms: ?entry.ObjectExpirationMs) Error!?entry.Object {
    return self.vtable.set(self.ptr, key, entry_object, exp_ms);
}

pub fn remove(self: Storage, key: []const u8) Error!void {
    return self.vtable.remove(self, key);
}

pub fn getExp(self: Storage, key: []const u8) Error!?entry.ObjectExpiration {
    return self.vtable.getExp(self, key);
}

pub fn setExp(self: Storage, key: []const u8, exp: entry.ObjectExpirationMs) Error!entry.ObjectExpiration {
    return self.vtable.setExp(self, key, exp);
}

pub fn clearExp(self: Storage, key: []const u8) Error!void {
    return self.vtable.clearExp(self, key);
}

pub fn deinit(self: Storage) void {
    self.vtable.deinit(self.ptr);
}
