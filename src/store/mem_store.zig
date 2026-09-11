const std = @import("std");
const Store = @import("interface.zig");
const Storage = @import("../storage/interface.zig");
const DefaultStorage = @import("../storage/default_storage.zig");
const persistence = @import("../persistence.zig");
const PersistenceState = @import("../persistence_state.zig");
const ChangeTracker = @import("../change_tracker.zig");
const entry = @import("../entry.zig");
const object = @import("../object.zig");
const Request = @import("../commander/request.zig");
const time = @import("../time.zig");
const testing = std.testing;

const MemoryStore = @This();

_allocator: std.mem.Allocator,
_storages: []const Storage,
_kgc: persistence.SnapshotPersistence,
_aof: ?persistence.JournalPersistence,
_change_tracker: *ChangeTracker,

/// Takes ownership of `storages`: `deinit` calls `Storage.deinit` on each.
pub fn init(allocator: std.mem.Allocator, storages: []const Storage, kgc: persistence.SnapshotPersistence, aof: ?persistence.JournalPersistence, tracker: *ChangeTracker) MemoryStore {
    return .{
        ._allocator = allocator,
        ._storages = storages,
        ._kgc = kgc,
        ._aof = aof,
        ._change_tracker = tracker,
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

pub fn remove(ptr: *anyopaque, key: []const u8, db_index: u32) Store.Error!bool {
    const self: *MemoryStore = @ptrCast(@alignCast(ptr));
    const storage = self._storages[db_index];

    var tx = storage.begin() catch return Store.Error.CancelledCommand;
    defer tx.end();

    const existed = storage.get(key) catch return Store.Error.SomethingWentWrong;
    storage.remove(key) catch return Store.Error.SomethingWentWrong;

    return existed != null;
}

pub fn dbsize(ptr: *anyopaque, db_index: u32) Store.Error!u32 {
    const self: *MemoryStore = @ptrCast(@alignCast(ptr));
    const storage = self._storages[db_index];

    var tx = storage.begin() catch return Store.Error.CancelledCommand;
    defer tx.end();

    return storage.size();
}

pub fn numDatabases(ptr: *anyopaque) u32 {
    const self: *MemoryStore = @ptrCast(@alignCast(ptr));
    return @intCast(self._storages.len);
}

pub fn save(ptr: *anyopaque) Store.Error!void {
    const self: *MemoryStore = @ptrCast(@alignCast(ptr));

    const sessions = try self.beginStorageSessions();
    defer self.endStorageSessions(sessions);

    self._kgc.save(self._storages) catch return Store.Error.UnableToSave;
}

pub fn bgsave(ptr: *anyopaque, origin: Store.TriggerOrigin) Store.Error!void {
    const self: *MemoryStore = @ptrCast(@alignCast(ptr));

    const sessions = try self.beginStorageSessions();
    defer self.endStorageSessions(sessions);

    self._kgc.bgsave(self._storages, origin) catch |err| {
        return switch (err) {
            error.SaveAlreadyInProgress => Store.Error.SaveAlreadyInProgress,
            else => Store.Error.UnableToBackgroundSaveKgc,
        };
    };
}

pub fn bgrewriteaof(ptr: *anyopaque, origin: Store.TriggerOrigin) Store.Error!void {
    const self: *MemoryStore = @ptrCast(@alignCast(ptr));
    const aof = self._aof orelse return Store.Error.AofDisabled;

    const sessions = try self.beginStorageSessions();
    defer self.endStorageSessions(sessions);

    var aof_tx = aof.begin() catch return Store.Error.UnableToRewriteAof;
    defer aof_tx.end();

    aof.bgRewrite(self._storages, origin) catch return Store.Error.UnableToRewriteAof;
}

fn beginStorageSessions(self: *MemoryStore) Store.Error![]Storage.Tx {
    const sessions = self._allocator.alloc(Storage.Tx, self._storages.len) catch return Store.Error.OutOfMemory;
    errdefer self._allocator.free(sessions);

    var count: usize = 0;
    errdefer while (count > 0) {
        count -= 1;
        sessions[count].end();
    };

    for (self._storages) |storage| {
        sessions[count] = storage.begin() catch return Store.Error.CancelledCommand;
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

const BeginProbeStorage = struct {
    inner: Storage,
    attempting: std.atomic.Value(bool) = .init(false),

    const probe_vtable: Storage.VTable = .{
        .begin = BeginProbeStorage.begin,
        .get = BeginProbeStorage.get,
        .put = BeginProbeStorage.put,
        .remove = BeginProbeStorage.remove,
        .removeIfExpired = BeginProbeStorage.removeIfExpired,
        .getExp = BeginProbeStorage.getExp,
        .setExp = BeginProbeStorage.setExp,
        .getExpirableCount = BeginProbeStorage.getExpirableCount,
        .sampleExpirableKey = BeginProbeStorage.sampleExpirableKey,
        .tryExpireRandom = BeginProbeStorage.tryExpireRandom,
        .clearExp = BeginProbeStorage.clearExp,
        .size = BeginProbeStorage.size,
        .forEach = BeginProbeStorage.forEach,
        .deinit = BeginProbeStorage.deinit,
    };

    fn storage(self: *BeginProbeStorage) Storage {
        return .{
            .ptr = self,
            .vtable = &probe_vtable,
            ._io = self.inner._io,
            ._lock = self.inner._lock,
        };
    }

    fn reset(self: *BeginProbeStorage) void {
        self.attempting.store(false, .release);
    }

    fn begin(ptr: *anyopaque) Storage.Error!Storage.Tx {
        const self: *BeginProbeStorage = @ptrCast(@alignCast(ptr));
        self.attempting.store(true, .release);
        return self.inner.begin();
    }

    fn get(ptr: *anyopaque, key: []const u8) Storage.Error!?entry.Object {
        const self: *BeginProbeStorage = @ptrCast(@alignCast(ptr));
        return self.inner.get(key);
    }

    fn put(ptr: *anyopaque, key: []const u8, value: object.Object, options: Storage.PutOptions) Storage.Error!entry.Object {
        const self: *BeginProbeStorage = @ptrCast(@alignCast(ptr));
        return self.inner.put(key, value, options);
    }

    fn remove(ptr: *anyopaque, key: []const u8) Storage.Error!void {
        const self: *BeginProbeStorage = @ptrCast(@alignCast(ptr));
        return self.inner.remove(key);
    }

    fn removeIfExpired(ptr: *anyopaque, key: []const u8) Storage.Error!bool {
        const self: *BeginProbeStorage = @ptrCast(@alignCast(ptr));
        return self.inner.removeIfExpired(key);
    }

    fn getExp(ptr: *anyopaque, key: []const u8) Storage.Error!?entry.ObjectExpiration {
        const self: *BeginProbeStorage = @ptrCast(@alignCast(ptr));
        return self.inner.getExp(key);
    }

    fn setExp(ptr: *anyopaque, key: []const u8, expires_at: ?time.UnixMs) Storage.Error!entry.ObjectExpiration {
        const self: *BeginProbeStorage = @ptrCast(@alignCast(ptr));
        return self.inner.setExp(key, expires_at);
    }

    fn getExpirableCount(ptr: *anyopaque) u32 {
        const self: *BeginProbeStorage = @ptrCast(@alignCast(ptr));
        return self.inner.getExpirableCount();
    }

    fn sampleExpirableKey(ptr: *anyopaque) Storage.Error!?[]const u8 {
        const self: *BeginProbeStorage = @ptrCast(@alignCast(ptr));
        return self.inner.sampleExpirableKey();
    }

    fn tryExpireRandom(ptr: *anyopaque) Storage.Error!?[]const u8 {
        const self: *BeginProbeStorage = @ptrCast(@alignCast(ptr));
        return self.inner.tryExpireRandom();
    }

    fn clearExp(ptr: *anyopaque, key: []const u8) Storage.Error!void {
        const self: *BeginProbeStorage = @ptrCast(@alignCast(ptr));
        return self.inner.clearExp(key);
    }

    fn size(ptr: *anyopaque) u32 {
        const self: *BeginProbeStorage = @ptrCast(@alignCast(ptr));
        return self.inner.size();
    }

    fn forEach(
        ptr: *anyopaque,
        ctx: *anyopaque,
        visit: *const fn (*anyopaque, []const u8, object.Object, ?time.UnixMs) anyerror!void,
    ) Storage.Error!void {
        const self: *BeginProbeStorage = @ptrCast(@alignCast(ptr));
        return self.inner.forEach(ctx, visit);
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *BeginProbeStorage = @ptrCast(@alignCast(ptr));
        self.inner.deinit();
    }
};

test "set stores a value and returns null" {
    var backend = DefaultStorage.init(testing.io, testing.allocator);
    var persistence_state = PersistenceState.init(testing.io, false);
    var kgc_backend = try persistence.KgcPersistence.init(testing.io, testing.allocator, &persistence_state, "test.kgc");
    var change_tracker = ChangeTracker.init(testing.io);
    var memory_store = MemoryStore.init(testing.allocator, &.{backend.storage()}, kgc_backend.snapshot(), null, &change_tracker);
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
    var persistence_state = PersistenceState.init(testing.io, false);
    var kgc_backend = try persistence.KgcPersistence.init(testing.io, testing.allocator, &persistence_state, "test.kgc");
    var change_tracker = ChangeTracker.init(testing.io);
    var memory_store = MemoryStore.init(testing.allocator, &.{backend.storage()}, kgc_backend.snapshot(), null, &change_tracker);
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
    var persistence_state = PersistenceState.init(testing.io, false);
    var kgc_backend = try persistence.KgcPersistence.init(testing.io, testing.allocator, &persistence_state, "test.kgc");
    var change_tracker = ChangeTracker.init(testing.io);
    var memory_store = MemoryStore.init(testing.allocator, &.{backend.storage()}, kgc_backend.snapshot(), null, &change_tracker);
    var data_store = memory_store.store();
    defer data_store.deinit();

    const value = try data_store.get("missing", 0);

    try testing.expect(value == null);
}

test "set replaces an existing value" {
    var backend = DefaultStorage.init(testing.io, testing.allocator);
    var persistence_state = PersistenceState.init(testing.io, false);
    var kgc_backend = try persistence.KgcPersistence.init(testing.io, testing.allocator, &persistence_state, "test.kgc");
    var change_tracker = ChangeTracker.init(testing.io);
    var memory_store = MemoryStore.init(testing.allocator, &.{backend.storage()}, kgc_backend.snapshot(), null, &change_tracker);
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
    var persistence_state = PersistenceState.init(testing.io, false);
    var kgc_backend = try persistence.KgcPersistence.init(testing.io, testing.allocator, &persistence_state, "test.kgc");
    var change_tracker = ChangeTracker.init(testing.io);
    var memory_store = MemoryStore.init(testing.allocator, &.{backend.storage()}, kgc_backend.snapshot(), null, &change_tracker);
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
    var persistence_state = PersistenceState.init(testing.io, false);
    var kgc_backend = try persistence.KgcPersistence.init(testing.io, testing.allocator, &persistence_state, "test.kgc");
    var change_tracker = ChangeTracker.init(testing.io);
    var memory_store = MemoryStore.init(testing.allocator, &.{backend.storage()}, kgc_backend.snapshot(), null, &change_tracker);
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
    var persistence_state = PersistenceState.init(testing.io, false);
    var kgc_backend = try persistence.KgcPersistence.init(testing.io, testing.allocator, &persistence_state, "test.kgc");
    var change_tracker = ChangeTracker.init(testing.io);
    var memory_store = MemoryStore.init(testing.allocator, &.{backend.storage()}, kgc_backend.snapshot(), null, &change_tracker);
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
    var persistence_state = PersistenceState.init(testing.io, false);
    var kgc_backend = try persistence.KgcPersistence.init(testing.io, testing.allocator, &persistence_state, "test.kgc");
    var change_tracker = ChangeTracker.init(testing.io);
    var memory_store = MemoryStore.init(testing.allocator, &.{ backend_zero.storage(), backend_one.storage() }, kgc_backend.snapshot(), null, &change_tracker);
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

test "save then load round-trips across databases" {
    var backend_zero = DefaultStorage.init(testing.io, testing.allocator);
    var backend_one = DefaultStorage.init(testing.io, testing.allocator);
    var persistence_state = PersistenceState.init(testing.io, false);
    var kgc_backend = try persistence.KgcPersistence.init(testing.io, testing.allocator, &persistence_state, "scratch-roundtrip.kgc");
    var change_tracker = ChangeTracker.init(testing.io);
    var memory_store = MemoryStore.init(testing.allocator, &.{ backend_zero.storage(), backend_one.storage() }, kgc_backend.snapshot(), null, &change_tracker);
    var data_store = memory_store.store();
    defer data_store.deinit();

    const expires_at = time.nowMs(testing.io) + 60_000;
    _ = try data_store.set(.{ .key = "foo", .value = "bar", .condition = null, .expires_at = null, .keepttl = false, .response = null }, 0);
    _ = try data_store.set(.{ .key = "baz", .value = "qux", .condition = null, .expires_at = expires_at, .keepttl = false, .response = null }, 1);

    try data_store.save(time.nowMs(testing.io));

    var fresh_zero = DefaultStorage.init(testing.io, testing.allocator);
    var fresh_one = DefaultStorage.init(testing.io, testing.allocator);
    var fresh_zero_storage = fresh_zero.storage();
    var fresh_one_storage = fresh_one.storage();
    defer fresh_zero_storage.deinit();
    defer fresh_one_storage.deinit();

    try kgc_backend.snapshot().load(&.{ fresh_zero_storage, fresh_one_storage });

    {
        var tx = try fresh_zero_storage.begin();
        defer tx.end();
        const loaded_foo = try fresh_zero_storage.get("foo") orelse return error.TestUnexpectedResult;
        try expectObjectString(loaded_foo.value, "bar");
    }
    {
        var tx = try fresh_one_storage.begin();
        defer tx.end();
        const loaded_baz = try fresh_one_storage.get("baz") orelse return error.TestUnexpectedResult;
        try expectObjectString(loaded_baz.value, "qux");
        try testing.expectEqual(1, fresh_one_storage.getExpirableCount());
    }
}

test "save resets the change tracker's dirty count" {
    const NotifierStorage = @import("../storage/notifier_storage.zig");

    var backend = DefaultStorage.init(testing.io, testing.allocator);
    var persistence_state = PersistenceState.init(testing.io, false);
    var kgc_backend = try persistence.KgcPersistence.init(testing.io, testing.allocator, &persistence_state, "scratch-save-reset.kgc");
    var change_tracker = ChangeTracker.init(testing.io);
    var notifier = NotifierStorage.init(testing.allocator, backend.storage(), null, &change_tracker, 0);
    var memory_store = MemoryStore.init(testing.allocator, &.{notifier.storage()}, kgc_backend.snapshot(), null, &change_tracker);
    var data_store = memory_store.store();
    defer data_store.deinit();

    // a real write through the store, not the test poking the tracker directly.
    _ = try data_store.set(.{ .key = "foo", .value = "bar", .condition = null, .expires_at = null, .keepttl = false, .response = null }, 0);
    try testing.expect(change_tracker._dirty.load(.monotonic) > 0);

    try data_store.save(time.nowMs(testing.io));

    try testing.expectEqual(0, change_tracker._dirty.load(.monotonic));
}

test "bgrewriteaof returns AofDisabled when no journal is configured" {
    var backend = DefaultStorage.init(testing.io, testing.allocator);
    var persistence_state = PersistenceState.init(testing.io, false);
    var kgc_backend = try persistence.KgcPersistence.init(testing.io, testing.allocator, &persistence_state, "test.kgc");
    var change_tracker = ChangeTracker.init(testing.io);
    var memory_store = MemoryStore.init(testing.allocator, &.{backend.storage()}, kgc_backend.snapshot(), null, &change_tracker);
    var data_store = memory_store.store();
    defer data_store.deinit();

    try testing.expectError(Store.Error.AofDisabled, data_store.bgrewriteaof(.manual));
}

test "AOF rewrite reports progress until completion and replays writes" {
    const Config = @import("../config.zig");
    const cwd = std.Io.Dir.cwd();
    const dirname = "scratch-mem-store-aof-rewrite-progress";

    cwd.deleteTree(testing.io, dirname) catch {};
    defer cwd.deleteTree(testing.io, dirname) catch {};

    var config = Config.default();
    config.append_only = true;
    config.append_dirname = dirname;

    var backend = DefaultStorage.init(testing.io, testing.allocator);
    var persistence_state = PersistenceState.init(testing.io, false);
    var kgc_backend = try persistence.KgcPersistence.init(testing.io, testing.allocator, &persistence_state, "test.kgc");
    var aof_backend = try persistence.AofPersistence.init(testing.io, testing.allocator, &persistence_state, config);
    const journal = aof_backend.journal();
    var change_tracker = ChangeTracker.init(testing.io);
    var memory_store = MemoryStore.init(testing.allocator, &.{backend.storage()}, kgc_backend.snapshot(), journal, &change_tracker);
    var data_store = memory_store.store();
    defer data_store.deinit();
    defer journal.deinit() catch {};

    _ = try data_store.set(.{
        .key = "foo",
        .value = "bar",
        .condition = null,
        .expires_at = null,
        .keepttl = false,
        .response = null,
    }, 0);

    try data_store.bgrewriteaof(.manual);
    {
        var state_tx = try persistence_state.begin();
        defer state_tx.end();
        try testing.expect(persistence_state.aofInProgress());
    }

    var result: PersistenceState.ReapResult = .running;
    var tries: usize = 0;
    while (result == .running) {
        var state_tx = try persistence_state.begin();
        result = persistence_state.reapAof();
        state_tx.end();
        tries += 1;
        if (tries > 100_000) return error.ChildNeverReaped;
    }
    try testing.expectEqual(PersistenceState.ReapResult.succeeded, result);
    {
        var state_tx = try persistence_state.begin();
        defer state_tx.end();
        try testing.expect(!persistence_state.aofInProgress());
    }

    {
        var tx = try journal.begin();
        defer tx.end();
        try journal.finishRewrite(result);
    }

    var fresh_backend = DefaultStorage.init(testing.io, testing.allocator);
    var fresh_state = PersistenceState.init(testing.io, false);
    var fresh_kgc = try persistence.KgcPersistence.init(testing.io, testing.allocator, &fresh_state, "test.kgc");
    var fresh_tracker = ChangeTracker.init(testing.io);
    var fresh_memory_store = MemoryStore.init(testing.allocator, &.{fresh_backend.storage()}, fresh_kgc.snapshot(), null, &fresh_tracker);
    var fresh_store = fresh_memory_store.store();
    defer fresh_store.deinit();

    _ = try persistence.AofLoader.replay(testing.io, testing.allocator, &fresh_store, config);
    const value = try fresh_store.get("foo", 0);
    try expectObjectString(value, "bar");
}

test "concurrent AOF rewrite and writes replay to the final value" {
    const Config = @import("../config.zig");
    const NotifierStorage = @import("../storage/notifier_storage.zig");
    const cwd = std.Io.Dir.cwd();
    const dirname = "scratch-concurrent-aof-rewrite";

    cwd.deleteTree(testing.io, dirname) catch {};
    defer cwd.deleteTree(testing.io, dirname) catch {};

    var config = Config.default();
    config.append_only = true;
    config.append_dirname = dirname;

    var backend = DefaultStorage.init(testing.io, testing.allocator);
    var persistence_state = PersistenceState.init(testing.io, false);
    var kgc_backend = try persistence.KgcPersistence.init(testing.io, testing.allocator, &persistence_state, "test.kgc");
    var aof_backend = try persistence.AofPersistence.init(testing.io, testing.allocator, &persistence_state, config);
    const journal = aof_backend.journal();
    defer journal.deinit() catch {};
    var change_tracker = ChangeTracker.init(testing.io);
    var notifier = NotifierStorage.init(testing.allocator, backend.storage(), journal, &change_tracker, 0);
    var memory_store = MemoryStore.init(testing.allocator, &.{notifier.storage()}, kgc_backend.snapshot(), journal, &change_tracker);
    var data_store = memory_store.store();
    defer data_store.deinit();

    try setStoreValue(&data_store, "key", "0", 0);
    try data_store.bgrewriteaof(.manual);

    var value_buffer: [32]u8 = undefined;
    var last_value: []const u8 = "0";
    for (1..101) |number| {
        const value = try std.fmt.bufPrint(&value_buffer, "{d}", .{number});
        try setStoreValue(&data_store, "key", value, 0);
        last_value = value;
    }

    var result: PersistenceState.ReapResult = .running;
    var tries: usize = 0;
    while (result == .running) {
        var state_tx = try persistence_state.begin();
        result = persistence_state.reapAof();
        state_tx.end();
        tries += 1;
        if (tries > 100_000) return error.ChildNeverReaped;
    }
    try testing.expectEqual(PersistenceState.ReapResult.succeeded, result);

    {
        var tx = try journal.begin();
        defer tx.end();
        try journal.finishRewrite(result);
        try journal.flush(time.nowMs(testing.io));
    }

    var fresh_backend = DefaultStorage.init(testing.io, testing.allocator);
    var fresh_state = PersistenceState.init(testing.io, false);
    var fresh_kgc = try persistence.KgcPersistence.init(testing.io, testing.allocator, &fresh_state, "test.kgc");
    var fresh_tracker = ChangeTracker.init(testing.io);
    var fresh_memory_store = MemoryStore.init(testing.allocator, &.{fresh_backend.storage()}, fresh_kgc.snapshot(), null, &fresh_tracker);
    var fresh_store = fresh_memory_store.store();
    defer fresh_store.deinit();

    _ = try persistence.AofLoader.replay(testing.io, testing.allocator, &fresh_store, config);
    try expectObjectString(try fresh_store.get("key", 0), last_value);
}

test "concurrent KGC snapshot contains one complete submitted value" {
    const cwd = std.Io.Dir.cwd();
    const path = "scratch-concurrent-kgc.kgc";

    cwd.deleteFile(testing.io, path) catch {};
    defer cwd.deleteFile(testing.io, path) catch {};

    const first = try testing.allocator.alloc(u8, 256 * 1024);
    defer testing.allocator.free(first);
    @memset(first, 0x35);
    const second = try testing.allocator.alloc(u8, 256 * 1024);
    defer testing.allocator.free(second);
    @memset(second, 0xca);

    var backend = DefaultStorage.init(testing.io, testing.allocator);
    var persistence_state = PersistenceState.init(testing.io, false);
    var kgc_backend = try persistence.KgcPersistence.init(testing.io, testing.allocator, &persistence_state, path);
    var change_tracker = ChangeTracker.init(testing.io);
    var memory_store = MemoryStore.init(testing.allocator, &.{backend.storage()}, kgc_backend.snapshot(), null, &change_tracker);
    var data_store = memory_store.store();
    defer data_store.deinit();

    try setStoreValue(&data_store, "key", first, 0);
    try data_store.bgsave(.manual);
    for (0..20) |index| {
        try setStoreValue(&data_store, "key", if (index % 2 == 0) second else first, 0);
    }

    const reap_ms = time.nowMs(testing.io);
    var result: PersistenceState.KgcReapResult = .{ .status = .running };
    var tries: usize = 0;
    while (result.status == .running) {
        var state_tx = try persistence_state.begin();
        result = persistence_state.reapKgc(reap_ms);
        if (result.status != .running) persistence_state.finishKgc();
        state_tx.end();
        tries += 1;
        if (tries > 100_000) return error.ChildNeverReaped;
    }
    try testing.expectEqual(PersistenceState.ReapResult.succeeded, result.status);

    var fresh_backend = DefaultStorage.init(testing.io, testing.allocator);
    var fresh_storage = fresh_backend.storage();
    defer fresh_storage.deinit();
    try kgc_backend.snapshot().load(&.{fresh_storage});

    var tx = try fresh_storage.begin();
    defer tx.end();
    const loaded = try fresh_storage.get("key") orelse return error.TestUnexpectedResult;
    switch (loaded.value) {
        .string => |value| try testing.expect(std.mem.eql(u8, value, first) or std.mem.eql(u8, value, second)),
    }
}

test "AOF rewrite waits for active Storage work and preserves all databases" {
    const Config = @import("../config.zig");
    const NotifierStorage = @import("../storage/notifier_storage.zig");
    const Context = struct {
        data_store: *Store,
        returned: std.atomic.Value(bool) = .init(false),
        failed: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            self.data_store.bgrewriteaof(.manual) catch self.failed.store(true, .release);
            self.returned.store(true, .release);
        }
    };
    const cwd = std.Io.Dir.cwd();
    const dirname = "scratch-aof-storage-wait";

    cwd.deleteTree(testing.io, dirname) catch {};
    defer cwd.deleteTree(testing.io, dirname) catch {};

    var config = Config.default();
    config.append_only = true;
    config.append_dirname = dirname;

    var backend_zero = DefaultStorage.init(testing.io, testing.allocator);
    var backend_one = DefaultStorage.init(testing.io, testing.allocator);
    var persistence_state = PersistenceState.init(testing.io, false);
    var kgc_backend = try persistence.KgcPersistence.init(testing.io, testing.allocator, &persistence_state, "test.kgc");
    var aof_backend = try persistence.AofPersistence.init(testing.io, testing.allocator, &persistence_state, config);
    const journal = aof_backend.journal();
    defer journal.deinit() catch {};
    var change_tracker = ChangeTracker.init(testing.io);
    var notifier_zero = NotifierStorage.init(testing.allocator, backend_zero.storage(), journal, &change_tracker, 0);
    var notifier_one = NotifierStorage.init(testing.allocator, backend_one.storage(), journal, &change_tracker, 1);
    var probe_one: BeginProbeStorage = .{ .inner = notifier_one.storage() };
    const storage_one = probe_one.storage();
    var memory_store = MemoryStore.init(testing.allocator, &.{ notifier_zero.storage(), storage_one }, kgc_backend.snapshot(), journal, &change_tracker);
    var data_store = memory_store.store();
    defer data_store.deinit();

    try setStoreValue(&data_store, "zero", "first", 0);
    try setStoreValue(&data_store, "one", "second", 1);

    var held = try storage_one.begin();
    probe_one.reset();
    var context: Context = .{ .data_store = &data_store };
    const thread = try std.Thread.spawn(.{}, Context.run, .{&context});

    while (!probe_one.attempting.load(.acquire) and !context.returned.load(.acquire)) std.atomic.spinLoopHint();
    const attempted = probe_one.attempting.load(.acquire);
    const returned_early = context.returned.load(.acquire);

    held.end();
    thread.join();

    try testing.expect(attempted);
    try testing.expect(!returned_early);
    try testing.expect(!context.failed.load(.acquire));

    var result: PersistenceState.ReapResult = .running;
    var tries: usize = 0;
    while (result == .running) {
        var state_tx = try persistence_state.begin();
        result = persistence_state.reapAof();
        state_tx.end();
        tries += 1;
        if (tries > 100_000) return error.ChildNeverReaped;
    }
    try testing.expectEqual(PersistenceState.ReapResult.succeeded, result);
    {
        var tx = try journal.begin();
        defer tx.end();
        try journal.finishRewrite(result);
    }

    var fresh_zero = DefaultStorage.init(testing.io, testing.allocator);
    var fresh_one = DefaultStorage.init(testing.io, testing.allocator);
    var fresh_state = PersistenceState.init(testing.io, false);
    var fresh_kgc = try persistence.KgcPersistence.init(testing.io, testing.allocator, &fresh_state, "test.kgc");
    var fresh_tracker = ChangeTracker.init(testing.io);
    var fresh_memory_store = MemoryStore.init(testing.allocator, &.{ fresh_zero.storage(), fresh_one.storage() }, fresh_kgc.snapshot(), null, &fresh_tracker);
    var fresh_store = fresh_memory_store.store();
    defer fresh_store.deinit();

    _ = try persistence.AofLoader.replay(testing.io, testing.allocator, &fresh_store, config);
    try expectObjectString(try fresh_store.get("zero", 0), "first");
    try expectObjectString(try fresh_store.get("one", 1), "second");
}

test "KGC bgsave waits for active Storage work and preserves all databases" {
    const Context = struct {
        data_store: *Store,
        returned: std.atomic.Value(bool) = .init(false),
        failed: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            self.data_store.bgsave(.manual) catch self.failed.store(true, .release);
            self.returned.store(true, .release);
        }
    };
    const cwd = std.Io.Dir.cwd();
    const path = "scratch-kgc-storage-wait.kgc";

    cwd.deleteFile(testing.io, path) catch {};
    defer cwd.deleteFile(testing.io, path) catch {};

    var backend_zero = DefaultStorage.init(testing.io, testing.allocator);
    var backend_one = DefaultStorage.init(testing.io, testing.allocator);
    var probe_one: BeginProbeStorage = .{ .inner = backend_one.storage() };
    const storage_one = probe_one.storage();
    var persistence_state = PersistenceState.init(testing.io, false);
    var kgc_backend = try persistence.KgcPersistence.init(testing.io, testing.allocator, &persistence_state, path);
    var change_tracker = ChangeTracker.init(testing.io);
    var memory_store = MemoryStore.init(testing.allocator, &.{ backend_zero.storage(), storage_one }, kgc_backend.snapshot(), null, &change_tracker);
    var data_store = memory_store.store();
    defer data_store.deinit();

    try setStoreValue(&data_store, "zero", "first", 0);
    try setStoreValue(&data_store, "one", "second", 1);

    var held = try storage_one.begin();
    probe_one.reset();
    var context: Context = .{ .data_store = &data_store };
    const thread = try std.Thread.spawn(.{}, Context.run, .{&context});

    while (!probe_one.attempting.load(.acquire) and !context.returned.load(.acquire)) std.atomic.spinLoopHint();
    const attempted = probe_one.attempting.load(.acquire);
    const returned_early = context.returned.load(.acquire);

    held.end();
    thread.join();

    try testing.expect(attempted);
    try testing.expect(!returned_early);
    try testing.expect(!context.failed.load(.acquire));

    const reap_ms = time.nowMs(testing.io);
    var result: PersistenceState.KgcReapResult = .{ .status = .running };
    var tries: usize = 0;
    while (result.status == .running) {
        var state_tx = try persistence_state.begin();
        result = persistence_state.reapKgc(reap_ms);
        if (result.status != .running) persistence_state.finishKgc();
        state_tx.end();
        tries += 1;
        if (tries > 100_000) return error.ChildNeverReaped;
    }
    try testing.expectEqual(PersistenceState.ReapResult.succeeded, result.status);

    var fresh_zero = DefaultStorage.init(testing.io, testing.allocator);
    var fresh_one = DefaultStorage.init(testing.io, testing.allocator);
    var fresh_zero_storage = fresh_zero.storage();
    var fresh_one_storage = fresh_one.storage();
    defer fresh_zero_storage.deinit();
    defer fresh_one_storage.deinit();
    try kgc_backend.snapshot().load(&.{ fresh_zero_storage, fresh_one_storage });

    {
        var tx = try fresh_zero_storage.begin();
        defer tx.end();
        const loaded = try fresh_zero_storage.get("zero") orelse return error.TestUnexpectedResult;
        try expectObjectString(loaded.value, "first");
    }
    {
        var tx = try fresh_one_storage.begin();
        defer tx.end();
        const loaded = try fresh_one_storage.get("one") orelse return error.TestUnexpectedResult;
        try expectObjectString(loaded.value, "second");
    }
}

fn setStoreValue(data_store: *Store, key: []const u8, value: []const u8, db_index: u32) !void {
    _ = try data_store.set(.{
        .key = key,
        .value = value,
        .condition = null,
        .expires_at = null,
        .keepttl = false,
        .response = null,
    }, db_index);
}

fn expectObjectString(maybe_value: ?object.Object, expected: []const u8) !void {
    const value = maybe_value orelse return error.Null;

    switch (value) {
        .string => |str| {
            try testing.expectEqualStrings(expected, str);
        },
    }
}
