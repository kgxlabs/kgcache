const std = @import("std");
const object = @import("../object.zig");
const Storage = @import("../storage/interface.zig");
const Request = @import("../commander/request.zig");

// NOTE: currently this is the optimal place that should own `TriggerOrigin`
// Other places like `PersistenceState` (persistence is not really a operation module) and `Commander` (circular deps) are not solid for now.
// TODO: If you find somewhere more optimal, you can refactor this
pub const TriggerOrigin = enum {
    manual,
    automatic,
};

pub const Error = std.mem.Allocator.Error || error{
    UnsupportedCondition,
    SomethingWentWrong,
    CancelledCommand,
    UnableToSave,
    UnableToBackgroundSaveKgc,
    UnableToRewriteAof,
    AofDisabled,
    SaveAlreadyInProgress,
};

const Store = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    get: *const fn (*anyopaque, []const u8, u32) Error!?object.Object,
    set: *const fn (*anyopaque, Request.SetRequest, u32) Error!?object.Object,
    remove: *const fn (*anyopaque, []const u8, u32) Error!bool,
    dbsize: *const fn (*anyopaque, u32) Error!u32,
    numDatabases: *const fn (*anyopaque) u32,
    save: *const fn (*anyopaque) Error!void,
    bgsave: *const fn (*anyopaque, TriggerOrigin) Error!void,
    bgrewriteaof: *const fn (*anyopaque, TriggerOrigin) Error!void,
    deinit: *const fn (*anyopaque) void,
};

pub fn get(self: Store, key: []const u8, db_index: u32) Error!?object.Object {
    return self.vtable.get(self.ptr, key, db_index);
}

pub fn set(self: Store, req: Request.SetRequest, db_index: u32) Error!?object.Object {
    return self.vtable.set(self.ptr, req, db_index);
}

pub fn remove(self: Store, key: []const u8, db_index: u32) Error!bool {
    return self.vtable.remove(self.ptr, key, db_index);
}

pub fn dbsize(self: Store, db_index: u32) Error!u32 {
    return self.vtable.dbsize(self.ptr, db_index);
}

pub fn numDatabases(self: Store) u32 {
    return self.vtable.numDatabases(self.ptr);
}

pub fn save(self: Store) Error!void {
    return self.vtable.save(self.ptr);
}

pub fn bgsave(self: Store, origin: TriggerOrigin) Error!void {
    return self.vtable.bgsave(self.ptr, origin);
}

pub fn bgrewriteaof(self: Store, origin: TriggerOrigin) Error!void {
    return self.vtable.bgrewriteaof(self.ptr, origin);
}

pub fn deinit(self: Store) void {
    self.vtable.deinit(self.ptr);
}
