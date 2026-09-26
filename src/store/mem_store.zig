const std = @import("std");
const Store = @import("interface.zig");
const Storage = @import("../storage/interface.zig");
const persistence = @import("../persistence.zig");
const PersistenceState = @import("../persistence_state.zig");
const object = @import("../object.zig");
const Request = @import("../commander/request.zig");

const MemoryStore = @This();

_allocator: std.mem.Allocator,
_storages: []const Storage,
_kgc: persistence.SnapshotPersistence,
_aof: ?persistence.JournalPersistence,

/// Takes ownership of `storages`: `deinit` calls `Storage.deinit` on each.
pub fn init(
    allocator: std.mem.Allocator,
    storages: []const Storage,
    kgc: persistence.SnapshotPersistence,
    aof: ?persistence.JournalPersistence,
) MemoryStore {
    return .{
        ._allocator = allocator,
        ._storages = storages,
        ._kgc = kgc,
        ._aof = aof,
    };
}

pub fn deinit(ptr: *anyopaque) void {
    const self: *MemoryStore = @ptrCast(@alignCast(ptr));
    for (self._storages) |s| s.deinit();
}

pub fn store(self: *MemoryStore) Store {
    return .{
        .ptr = self,
        .vtable = &vtable,
    };
}

const vtable = Store.VTable{
    .get = get,
    .set = set,
    .remove = remove,
    .dbsize = dbsize,
    .numDatabases = numDatabases,
    .save = save,
    .bgsave = bgsave,
    .bgrewriteaof = bgrewriteaof,
    .dispatchPendingBgsave = dispatchPendingBgsave,
    .dispatchPendingAofRewrite = dispatchPendingAofRewrite,
    .deinit = deinit,
};

pub fn get(ptr: *anyopaque, key: []const u8, db_index: u32) anyerror!?object.Owned {
    const self: *MemoryStore = @ptrCast(@alignCast(ptr));
    const storage = self._storages[db_index];
    var tx = try storage.begin();
    defer tx.end();

    const maybe_value = try storage.get(key);
    const value = maybe_value orelse return null;
    return try object.Owned.clone(self._allocator, value.value);
}

// TODO: Support all of these options
// SET key value [NX | XX | IFEQ ifeq-value | IFNE ifne-value |
// IFDEQ ifdeq-digest | IFDNE ifdne-digest] [GET] [EX seconds |
// PX milliseconds | EXAT unix-time-seconds |
// PXAT unix-time-milliseconds | KEEPTTL]
pub fn set(ptr: *anyopaque, req: Request.SetRequest, db_index: u32) anyerror!Store.SetResult {
    const self: *MemoryStore = @ptrCast(@alignCast(ptr));
    const storage = self._storages[db_index];

    try validateCondition(req.condition);

    var tx = try storage.begin();
    defer tx.end();

    const existing_entry = try storage.get(req.key);
    if (existing_entry != null and shouldSkipIfExist(req.condition)) {
        return .{
            .outcome = .not_applied,
            .value = try makeSetResponse(self, req, existing_entry.?.value),
        };
    }

    if (existing_entry == null and shouldSkipIfNotExist(req.condition)) {
        return .{
            .outcome = .not_applied,
            .value = try makeSetResponse(self, req, null),
        };
    }

    var response = try makeSetResponse(
        self,
        req,
        if (existing_entry) |existing| existing.value else null,
    );
    errdefer if (response) |*value| value.deinit();

    _ = try storage.put(req.key, .{
        .string = req.value,
    }, .{
        .expires_at = req.expires_at,
        .keepttl = req.keepttl,
    });

    return .{
        .outcome = .applied,
        .value = response,
    };
}

pub fn remove(ptr: *anyopaque, key: []const u8, db_index: u32) anyerror!Store.RemoveResult {
    const self: *MemoryStore = @ptrCast(@alignCast(ptr));
    const storage = self._storages[db_index];

    var tx = try storage.begin();
    defer tx.end();

    const existed = try storage.get(key);
    try storage.remove(key);

    return .{
        .outcome = if (existed != null) .applied else .not_applied,
        .value = {},
    };
}

pub fn dbsize(ptr: *anyopaque, db_index: u32) anyerror!u32 {
    const self: *MemoryStore = @ptrCast(@alignCast(ptr));
    const storage = self._storages[db_index];

    var tx = try storage.begin();
    defer tx.end();

    return storage.size();
}

pub fn numDatabases(ptr: *anyopaque) u32 {
    const self: *MemoryStore = @ptrCast(@alignCast(ptr));
    return @intCast(self._storages.len);
}

pub fn save(ptr: *anyopaque) anyerror!void {
    const self: *MemoryStore = @ptrCast(@alignCast(ptr));

    const sessions = try self.beginStorageSessions();
    defer self.endStorageSessions(sessions);

    try self._kgc.save(self._storages);
}

pub fn bgsave(ptr: *anyopaque, origin: Store.TriggerOrigin) anyerror!PersistenceState.BackgroundStartOutcome {
    const self: *MemoryStore = @ptrCast(@alignCast(ptr));

    const sessions = try self.beginStorageSessions();
    defer self.endStorageSessions(sessions);

    return self._kgc.bgsave(self._storages, origin);
}

pub fn bgrewriteaof(ptr: *anyopaque, origin: Store.TriggerOrigin) anyerror!PersistenceState.BackgroundStartOutcome {
    const self: *MemoryStore = @ptrCast(@alignCast(ptr));
    const aof = self._aof orelse return error.AofDisabled;

    const sessions = try self.beginStorageSessions();
    defer self.endStorageSessions(sessions);

    var aof_tx = try aof.begin();
    defer aof_tx.end();

    return aof.bgRewrite(self._storages, origin);
}

pub fn dispatchPendingBgsave(ptr: *anyopaque) anyerror!bool {
    const self: *MemoryStore = @ptrCast(@alignCast(ptr));
    const sessions = try self.beginStorageSessions();
    defer self.endStorageSessions(sessions);

    return self._kgc.dispatchPendingSave(self._storages);
}

pub fn dispatchPendingAofRewrite(ptr: *anyopaque) anyerror!bool {
    const self: *MemoryStore = @ptrCast(@alignCast(ptr));
    const aof = self._aof orelse return false;
    const sessions = try self.beginStorageSessions();
    defer self.endStorageSessions(sessions);

    var aof_tx = try aof.begin();
    defer aof_tx.end();

    return aof.dispatchPendingRewrite(self._storages);
}

fn beginStorageSessions(self: *MemoryStore) ![]Storage.Tx {
    const sessions = try self._allocator.alloc(Storage.Tx, self._storages.len);
    errdefer self._allocator.free(sessions);

    var count: usize = 0;
    errdefer while (count > 0) {
        count -= 1;
        sessions[count].end();
    };

    for (self._storages) |storage| {
        sessions[count] = try storage.begin();
        count += 1;
    }

    return sessions;
}

fn endStorageSessions(self: *MemoryStore, sessions: []Storage.Tx) void {
    var count = sessions.len;
    while (count > 0) {
        count -= 1;
        sessions[count].end();
    }
    self._allocator.free(sessions);
}

fn shouldSkipIfExist(maybe_condition: ?Request.SetCondition) bool {
    if (maybe_condition) |condition| {
        return switch (condition) {
            .nx => true,
            .xx => false,
            else => false,
        };
    }
    return false;
}

fn shouldSkipIfNotExist(maybe_condition: ?Request.SetCondition) bool {
    if (maybe_condition) |condition| {
        return switch (condition) {
            .nx => false,
            .xx => true,
            else => false,
        };
    }
    return false;
}

fn validateCondition(maybe_condition: ?Request.SetCondition) error{UnsupportedCondition}!void {
    if (maybe_condition) |condition| switch (condition) {
        .nx, .xx => {},
        else => return error.UnsupportedCondition,
    };
}

fn makeSetResponse(self: *MemoryStore, req: Request.SetRequest, value: ?object.Object) !?object.Owned {
    if (req.response != null and req.response.?.get) {
        return try object.Owned.clone(self._allocator, value orelse return null);
    }

    return null;
}
