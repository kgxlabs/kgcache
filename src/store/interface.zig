const std = @import("std");
const object = @import("../object.zig");
const Request = @import("../commander/request.zig");

pub const Error = std.mem.Allocator.Error || error{
    UnsupportedCondition,
    SomethingWentWrong,
};

const Store = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    get: *const fn (*anyopaque, std.Io, []const u8) Error!?object.Object,
    set: *const fn (*anyopaque, std.Io, Request.SetRequest) Error!?object.Object,
    deinit: *const fn (*anyopaque) void,
};

pub fn get(self: Store, io: std.Io, key: []const u8) Error!?object.Object {
    return self.vtable.get(self.ptr, io, key);
}

pub fn set(self: Store, io: std.Io, req: Request.SetRequest) Error!?object.Object {
    return self.vtable.set(self.ptr, io, req);
}

pub fn deinit(self: Store) void {
    self.vtable.deinit(self.ptr);
}
