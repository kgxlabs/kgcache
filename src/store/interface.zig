const std = @import("std");
const object = @import("../object.zig");
const Storage = @import("../storage/interface.zig");
const Request = @import("../commander/request.zig");
const PersistenceState = @import("../persistence_state.zig");

// NOTE: currently this is the optimal place that should own `TriggerOrigin`
// Other places like `PersistenceState` (persistence is not really a operation module) and `Commander` (circular deps) are not solid for now.
// TODO: If you find somewhere more optimal, you can refactor this
pub const TriggerOrigin = enum {
    manual,
    automatic,
};

const Store = @This();

// Mutation commands can complete without applying a change. Keep that outcome
// separate from any value the command asks the store to return.
pub const MutationOutcome = enum {
    applied,
    not_applied,
};

pub fn MutationResult(comptime T: type) type {
    return struct {
        outcome: MutationOutcome,
        value: T,
    };
}

pub const SetResult = MutationResult(?object.Owned);
pub const RemoveResult = MutationResult(void);

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    get: *const fn (*anyopaque, []const u8, u32) anyerror!?object.Owned,
    set: *const fn (*anyopaque, Request.SetRequest, u32) anyerror!SetResult,
    remove: *const fn (*anyopaque, []const u8, u32) anyerror!RemoveResult,
    dbsize: *const fn (*anyopaque, u32) anyerror!u32,
    numDatabases: *const fn (*anyopaque) u32,
    save: *const fn (*anyopaque) anyerror!void,
    bgsave: *const fn (*anyopaque, TriggerOrigin) anyerror!PersistenceState.BackgroundStartOutcome,
    bgrewriteaof: *const fn (*anyopaque, TriggerOrigin) anyerror!PersistenceState.BackgroundStartOutcome,
    deinit: *const fn (*anyopaque) void,
};

/// The caller owns a non-null result and must call `deinit` on it.
pub fn get(self: Store, key: []const u8, db_index: u32) anyerror!?object.Owned {
    return self.vtable.get(self.ptr, key, db_index);
}

/// The caller owns a non-null `result.value` and must call `deinit` on it.
pub fn set(self: Store, req: Request.SetRequest, db_index: u32) anyerror!SetResult {
    return self.vtable.set(self.ptr, req, db_index);
}

pub fn remove(self: Store, key: []const u8, db_index: u32) anyerror!RemoveResult {
    return self.vtable.remove(self.ptr, key, db_index);
}

pub fn dbsize(self: Store, db_index: u32) anyerror!u32 {
    return self.vtable.dbsize(self.ptr, db_index);
}

pub fn numDatabases(self: Store) u32 {
    return self.vtable.numDatabases(self.ptr);
}

pub fn save(self: Store) anyerror!void {
    return self.vtable.save(self.ptr);
}

pub fn bgsave(self: Store, origin: TriggerOrigin) anyerror!PersistenceState.BackgroundStartOutcome {
    return self.vtable.bgsave(self.ptr, origin);
}

pub fn bgrewriteaof(self: Store, origin: TriggerOrigin) anyerror!PersistenceState.BackgroundStartOutcome {
    return self.vtable.bgrewriteaof(self.ptr, origin);
}

pub fn deinit(self: Store) void {
    self.vtable.deinit(self.ptr);
}
