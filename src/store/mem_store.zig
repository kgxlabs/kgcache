const std = @import("std");
const Store = @import("interface.zig");
const Storage = @import("../storage/interface.zig");
const DefaultStorage = @import("../storage/default_storage.zig");
const persistence = @import("../persistence.zig");
const object = @import("../object.zig");
const Request = @import("../commander/request.zig");
const testing = std.testing;

const MemoryStore = @This();

_storages: []const Storage,
_rdb: persistence.SnapshotPersistence,

/// Takes ownership of `storages`: `deinit` calls `Storage.deinit` on each.
pub fn init(storages: []const Storage, rdb: persistence.SnapshotPersistence) MemoryStore {
    return .{
        ._storages = storages,
        ._rdb = rdb,
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
    .dbsize = dbsize,
    .numDatabases = numDatabases,
    .save = save,
    .deinit = deinit,
};

pub fn get(ptr: *anyopaque, key: []const u8, db_index: u32) Store.Error!?object.Object {
    const self: *MemoryStore = @ptrCast(@alignCast(ptr));
    const storage = self._storages[db_index];
    var tx = storage.begin() catch return Store.Error.CancelledCommand;
    defer tx.end();

    // TODO: Refactor with robust error propagation design
    const maybe_value = storage.get(key) catch return Store.Error.SomethingWentWrong;
    const value = maybe_value orelse return null;
    return value.value;
}

// TODO: Support all of these options
// SET key value [NX | XX | IFEQ ifeq-value | IFNE ifne-value |
// IFDEQ ifdeq-digest | IFDNE ifdne-digest] [GET] [EX seconds |
// PX milliseconds | EXAT unix-time-seconds |
// PXAT unix-time-milliseconds | KEEPTTL]
pub fn set(ptr: *anyopaque, req: Request.SetRequest, db_index: u32) Store.Error!?object.Object {
    const self: *MemoryStore = @ptrCast(@alignCast(ptr));
    const storage = self._storages[db_index];

    try validateCondition(req.condition);

    var tx = storage.begin() catch return Store.Error.CancelledCommand;
    defer tx.end();

    // TODO: Refactor with robust error propagation design
    const existing_entry = storage.get(req.key) catch return Store.Error.SomethingWentWrong;
    if (existing_entry != null and shouldSkipIfExist(req.condition)) {
        return makeSetResponse(req, existing_entry.?.value);
    }

    if (existing_entry == null and shouldSkipIfNotExist(req.condition)) {
        return makeSetResponse(req, null);
    }

    // TODO: Refactor with robust error propagation design
    const stored_entry = storage.put(req.key, .{
        .string = req.value,
    }, .{
        .expires_at = req.expires_at,
        .keepttl = req.keepttl,
    }) catch return Store.Error.SomethingWentWrong;

    return makeSetResponse(req, stored_entry.value);
}

pub fn dbsize(ptr: *anyopaque, db_index: u32) u32 {
    const self: *MemoryStore = @ptrCast(@alignCast(ptr));
    return self._storages[db_index].size();
}

pub fn numDatabases(ptr: *anyopaque) u32 {
    const self: *MemoryStore = @ptrCast(@alignCast(ptr));
    return @intCast(self._storages.len);
}

pub fn save(ptr: *anyopaque) Store.Error!void {
    const self: *MemoryStore = @ptrCast(@alignCast(ptr));
    self._rdb.save(self._storages[0]) catch return Store.Error.SomethingWentWrong;
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

fn validateCondition(maybe_condition: ?Request.SetCondition) Store.Error!void {
    if (maybe_condition) |condition| switch (condition) {
        .nx, .xx => {},
        else => return error.UnsupportedCondition,
    };
}

fn makeSetResponse(req: Request.SetRequest, value: ?object.Object) ?object.Object {
    if (req.response != null and req.response.?.get) {
        return value;
    }

    return null;
}

test "set stores a value and returns null" {
    var backend = DefaultStorage.init(testing.io, testing.allocator);
    var rdb_backend = persistence.RdbPersistence.init();
    var memory_store = MemoryStore.init(&.{backend.storage()}, rdb_backend.snapshot());
    var data_store = memory_store.store();

    defer data_store.deinit();

    const req: Request.SetRequest = .{
        .key = "foo",
        .value = "barz",
        .condition = null,
        .expires_at = null,
        .keepttl = false,
        .response = null,
    };
    const set_value = try data_store.set(req, 0);

    try testing.expect(set_value == null);

    const get_value = try data_store.get(req.key, 0) orelse return error.TestUnexpectedResult;
    try expectObjectString(get_value, req.value);
}

test "set stores a value and returns value" {
    var backend = DefaultStorage.init(testing.io, testing.allocator);
    var rdb_backend = persistence.RdbPersistence.init();
    var memory_store = MemoryStore.init(&.{backend.storage()}, rdb_backend.snapshot());
    var data_store = memory_store.store();
    defer data_store.deinit();

    const req: Request.SetRequest = .{
        .key = "foo",
        .value = "barz",
        .condition = null,
        .expires_at = null,
        .keepttl = false,
        .response = .{ .get = true },
    };

    const set_value = try data_store.set(req, 0);

    try expectObjectString(set_value, req.value);

    const get_value = try data_store.get(req.key, 0) orelse return error.TestUnexpectedResult;
    try expectObjectString(get_value, req.value);
}

test "get returns null for a missing key" {
    var backend = DefaultStorage.init(testing.io, testing.allocator);
    var rdb_backend = persistence.RdbPersistence.init();
    var memory_store = MemoryStore.init(&.{backend.storage()}, rdb_backend.snapshot());
    var data_store = memory_store.store();
    defer data_store.deinit();

    const value = try data_store.get("missing", 0);

    try testing.expect(value == null);
}

test "set replaces an existing value" {
    var backend = DefaultStorage.init(testing.io, testing.allocator);
    var rdb_backend = persistence.RdbPersistence.init();
    var memory_store = MemoryStore.init(&.{backend.storage()}, rdb_backend.snapshot());
    var data_store = memory_store.store();
    defer data_store.deinit();

    const first_req: Request.SetRequest = .{
        .key = "key",
        .value = "first",
        .condition = null,
        .expires_at = null,
        .keepttl = false,
        .response = null,
    };
    _ = try data_store.set(first_req, 0);

    const second_req: Request.SetRequest = .{
        .key = "key",
        .value = "second",
        .condition = null,
        .expires_at = null,
        .keepttl = false,
        .response = null,
    };

    const result = try data_store.set(second_req, 0);

    try testing.expect(result == null);

    const value = try data_store.get("key", 0) orelse return error.TestUnexpectedResult;
    try expectObjectString(value, "second");
}

test "set with NX does not replace an existing value" {
    var backend = DefaultStorage.init(testing.io, testing.allocator);
    var rdb_backend = persistence.RdbPersistence.init();
    var memory_store = MemoryStore.init(&.{backend.storage()}, rdb_backend.snapshot());
    var data_store = memory_store.store();
    defer data_store.deinit();

    _ = try data_store.set(.{
        .key = "key",
        .value = "first",
        .condition = null,
        .expires_at = null,
        .keepttl = false,
        .response = null,
    }, 0);
    _ = try data_store.set(.{
        .key = "key",
        .value = "second",
        .condition = .nx,
        .expires_at = null,
        .keepttl = false,
        .response = null,
    }, 0);

    const value = try data_store.get("key", 0) orelse return error.TestUnexpectedResult;
    try expectObjectString(value, "first");
}

test "set with XX does not create a missing value" {
    var backend = DefaultStorage.init(testing.io, testing.allocator);
    var rdb_backend = persistence.RdbPersistence.init();
    var memory_store = MemoryStore.init(&.{backend.storage()}, rdb_backend.snapshot());
    var data_store = memory_store.store();
    defer data_store.deinit();

    _ = try data_store.set(.{
        .key = "missing",
        .value = "value",
        .condition = .xx,
        .expires_at = null,
        .keepttl = false,
        .response = null,
    }, 0);

    try testing.expect(try data_store.get("missing", 0) == null);
}

test "set owns the key and value bytes" {
    var backend = DefaultStorage.init(testing.io, testing.allocator);
    var rdb_backend = persistence.RdbPersistence.init();
    var memory_store = MemoryStore.init(&.{backend.storage()}, rdb_backend.snapshot());
    var data_store = memory_store.store();
    defer data_store.deinit();

    var key = [_]u8{ 'k', 'e', 'y' };
    var value = [_]u8{ 'o', 'n', 'e' };

    const req: Request.SetRequest = .{
        .key = &key,
        .value = &value,
        .condition = null,
        .expires_at = null,
        .keepttl = false,
        .response = null,
    };
    _ = try data_store.set(req, 0);

    @memset(&key, 'x');
    @memset(&value, 'x');

    const stored_value = try data_store.get("key", 0) orelse return error.TestUnexpectedResult;
    try expectObjectString(stored_value, "one");
}

test "databases are isolated from each other" {
    var backend_zero = DefaultStorage.init(testing.io, testing.allocator);
    var backend_one = DefaultStorage.init(testing.io, testing.allocator);
    var rdb_backend = persistence.RdbPersistence.init();
    var memory_store = MemoryStore.init(&.{ backend_zero.storage(), backend_one.storage() }, rdb_backend.snapshot());
    var data_store = memory_store.store();
    defer data_store.deinit();

    _ = try data_store.set(.{
        .key = "key",
        .value = "value",
        .condition = null,
        .expires_at = null,
        .keepttl = false,
        .response = null,
    }, 0);

    try testing.expect(try data_store.get("key", 1) == null);

    const value = try data_store.get("key", 0) orelse return error.TestUnexpectedResult;
    try expectObjectString(value, "value");
}

fn expectObjectString(maybe_value: ?object.Object, expected: []const u8) !void {
    const value = maybe_value orelse return error.Null;

    switch (value) {
        .string => |str| {
            try testing.expectEqualStrings(expected, str);
        },
    }
}
