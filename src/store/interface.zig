const std = @import("std");
const object = @import("../object.zig");
const Request = @import("../commander/request.zig");

pub const Error = std.mem.Allocator.Error || error{};

const Store = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    get: *const fn (*anyopaque, []const u8) Error!?object.Object,
    set: *const fn (*anyopaque, Request.SetRequest) Error!?object.Object,
    deinit: *const fn (*anyopaque) void,
};

pub fn get(self: Store, key: []const u8) Error!?object.Object {
    return self.vtable.get(self.ptr, key);
}

pub fn set(self: Store, req: Request.SetRequest) Error!?object.Object {
    return self.vtable.set(self.ptr, req);
}

pub fn deinit(self: Store) void {
    self.vtable.deinit(self.ptr);
}
