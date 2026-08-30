// NOTE: This is a wrapper around real storage backend
// This storage is only responsible for notifying the persistence backends when a operation happens
// There should be no actual storage logic in this file

const std = @import("std");
const persistence = @import("../persistence.zig");
const Storage = @import("interface.zig");
const entry = @import("../entry.zig");
const object = @import("../object.zig");
const time = @import("../time.zig");
const helpers = @import("../helpers.zig");
const ChangeTracker = @import("../change_tracker.zig");
const DefaultStorage = @import("default_storage.zig");

const NotifierStorage = @This();

_allocator: std.mem.Allocator,
_inner: Storage,
// AOF is optional: write-log notifications are only sent if a journal backend is configured.
// KGC snapshotting is not routed through here: it needs a `Storage` handle to enumerate
// every key, not a per-write hook, so it lives at the `Store` level instead (see MemoryStore).
_aof: ?persistence.JournalPersistence,
// Shared across every db's NotifierStorage: the dirty count is process-wide, not per-database.
_change_tracker: *ChangeTracker,
_db_index: u32,

const vtable: Storage.VTable = .{
    .begin = begin,
    .get = get,
    .put = put,
    .remove = remove,
    .getExp = getExp,
    .setExp = setExp,
    .clearExp = clearExp,
    .removeIfExpired = removeIfExpired,
    .getExpirableCount = getExpirableCount,
    .tryExpireRandom = tryExpireRandom,
    .deinit = deinit,
    .size = size,
    .forEach = forEach,
};

pub fn storage(self: *NotifierStorage) Storage {
    return .{
        .ptr = self,
        .vtable = &vtable,
        ._io = self._inner._io,
        ._mutex = self._inner._mutex,
    };
}

pub fn init(
    allocator: std.mem.Allocator,
    inner: Storage,
    aof: ?persistence.JournalPersistence,
    change_tracker: *ChangeTracker,
    db_index: u32,
) NotifierStorage {
    return .{
        ._allocator = allocator,
        ._inner = inner,
        ._aof = aof,
        ._change_tracker = change_tracker,
        ._db_index = db_index,
    };
}

pub fn begin(ptr: *anyopaque) Storage.Error!Storage.Tx {
    var self: *NotifierStorage = @ptrCast(@alignCast(ptr));
    return self._inner.begin();
}

// TODO: Figure out do we need to clean up our own or not here
pub fn deinit(ptr: *anyopaque) void {
    const self: *NotifierStorage = @ptrCast(@alignCast(ptr));
    return self._inner.deinit();
}

pub fn get(ptr: *anyopaque, key: []const u8) Storage.Error!?entry.Object {
    const self: *NotifierStorage = @ptrCast(@alignCast(ptr));
    // NOTE: `get` can silently remove `key` as a side effect (lazy expiration,
    // below), but that removal is not observable without coupling with the persistence layer
    // So instead of relying on concrete storage get removal, we are doing that operation in advance
    // so when concrete `get` checks for removal it will already be removed
    const is_removed = try self._inner.removeIfExpired(key);

    if (is_removed) {
        self._change_tracker.recordChange();
        if (self._aof) |aof| {
            // TODO: improve error mapping after error map design imp
            aof.onWrite(.{
                .remove = .{ .db_index = self._db_index, .key = key },
            }) catch return Storage.Error.UnableToRecordWrite;
        }
    }

    return self._inner.get(key);
}

pub fn put(ptr: *anyopaque, key: []const u8, value: object.Object, options: Storage.PutOptions) Storage.Error!entry.Object {
    const self: *NotifierStorage = @ptrCast(@alignCast(ptr));
    const result = try self._inner.put(key, value, options);
    self._change_tracker.recordChange();

    if (self._aof) |aof| {
        const maybe_exp = try self._inner.getExp(key);
        const expires_at: ?time.UnixMs = if (maybe_exp) |exp| exp.expires_at else null;

        // TODO: improve error mapping after error map design imp
        aof.onWrite(.{ .put = .{
            .db_index = self._db_index,
            .key = key,
            .value = value,
            .expires_at = expires_at,
        } }) catch return Storage.Error.UnableToRecordWrite;
    }

    return result;
}

pub fn remove(ptr: *anyopaque, key: []const u8) Storage.Error!void {
    const self: *NotifierStorage = @ptrCast(@alignCast(ptr));
    try self._inner.remove(key);
    self._change_tracker.recordChange();
}

pub fn removeIfExpired(ptr: *anyopaque, key: []const u8) Storage.Error!bool {
    const self: *NotifierStorage = @ptrCast(@alignCast(ptr));
    return self._inner.removeIfExpired(key);
}

pub fn getExp(ptr: *anyopaque, key: []const u8) Storage.Error!?entry.ObjectExpiration {
    const self: *NotifierStorage = @ptrCast(@alignCast(ptr));
    return self._inner.getExp(key);
}

pub fn setExp(ptr: *anyopaque, key: []const u8, exp: ?time.UnixMs) Storage.Error!entry.ObjectExpiration {
    const self: *NotifierStorage = @ptrCast(@alignCast(ptr));
    return self._inner.setExp(key, exp);
}

pub fn tryExpireRandom(ptr: *anyopaque) Storage.Error!?[]const u8 {
    const self: *NotifierStorage = @ptrCast(@alignCast(ptr));
    return self._inner.tryExpireRandom();
}

pub fn getExpirableCount(ptr: *anyopaque) u32 {
    const self: *NotifierStorage = @ptrCast(@alignCast(ptr));
    return self._inner.getExpirableCount();
}

pub fn clearExp(ptr: *anyopaque, key: []const u8) Storage.Error!void {
    const self: *NotifierStorage = @ptrCast(@alignCast(ptr));
    return self._inner.clearExp(key);
}

pub fn size(ptr: *anyopaque) u32 {
    const self: *NotifierStorage = @ptrCast(@alignCast(ptr));
    return self._inner.size();
}

pub fn forEach(ptr: *anyopaque, ctx: *anyopaque, visit: *const fn (ctx: *anyopaque, key: []const u8, value: object.Object, exp: ?time.UnixMs) anyerror!void) Storage.Error!void {
    const self: *NotifierStorage = @ptrCast(@alignCast(ptr));
    return self._inner.forEach(ctx, visit);
}

test "put increments the change tracker's dirty count" {
    const testing = std.testing;

    var backend = DefaultStorage.init(testing.io, testing.allocator);
    var tracker = ChangeTracker.init(testing.io);
    var notifier = NotifierStorage.init(testing.allocator, backend.storage(), null, &tracker, 0);
    var wrapped = notifier.storage();
    defer wrapped.deinit();

    var tx = try wrapped.begin();
    defer tx.end();

    _ = try wrapped.put("foo", .{ .string = "bar" }, .{ .expires_at = null });

    try testing.expectEqual(1, tracker._dirty.load(.monotonic));
}

test "remove increments the change tracker's dirty count" {
    const testing = std.testing;

    var backend = DefaultStorage.init(testing.io, testing.allocator);
    var tracker = ChangeTracker.init(testing.io);
    var notifier = NotifierStorage.init(testing.allocator, backend.storage(), null, &tracker, 0);
    var wrapped = notifier.storage();
    defer wrapped.deinit();

    var tx = try wrapped.begin();
    defer tx.end();

    _ = try wrapped.put("foo", .{ .string = "bar" }, .{ .expires_at = null });
    try wrapped.remove("foo");

    try testing.expectEqual(2, tracker._dirty.load(.monotonic));
}

test "a lazy-expiration removal during get increments the change tracker's dirty count" {
    const testing = std.testing;

    var backend = DefaultStorage.init(testing.io, testing.allocator);
    var tracker = ChangeTracker.init(testing.io);
    var notifier = NotifierStorage.init(testing.allocator, backend.storage(), null, &tracker, 0);
    var wrapped = notifier.storage();
    defer wrapped.deinit();

    var tx = try wrapped.begin();
    defer tx.end();

    _ = try wrapped.put("expired", .{ .string = "value" }, .{
        .expires_at = time.nowMs(testing.io) - 1,
    });
    try testing.expectEqual(1, tracker._dirty.load(.monotonic));

    try testing.expect(try wrapped.get("expired") == null);

    try testing.expectEqual(2, tracker._dirty.load(.monotonic));
}

const FailingJournal = struct {
    const journal_vtable: persistence.JournalPersistence.VTable = .{
        .onWrite = onWrite,
        .flush = flush,
        .bgRewrite = bgRewrite,
        .finishRewrite = finishRewrite,
        .deinit = journalDeinit,
    };

    fn journal(self: *FailingJournal) persistence.JournalPersistence {
        return .{ .ptr = self, .vtable = &journal_vtable };
    }

    fn onWrite(_: *anyopaque, _: persistence.JournalPersistence.WriteEvent) persistence.JournalPersistence.Error!void {
        return error.UnableToRecordWrite;
    }

    fn flush(_: *anyopaque, _: i64) persistence.JournalPersistence.Error!void {}
    fn bgRewrite(_: *anyopaque) persistence.JournalPersistence.Error!void {}
    fn finishRewrite(_: *anyopaque, _: bool) persistence.JournalPersistence.Error!void {}
    fn journalDeinit(_: *anyopaque) persistence.JournalPersistence.Error!void {}
};

test "a journal that fails to record a write fails the put" {
    const testing = std.testing;

    var backend = DefaultStorage.init(testing.io, testing.allocator);
    var tracker = ChangeTracker.init(testing.io);
    var failing_journal = FailingJournal{};
    var notifier = NotifierStorage.init(
        testing.allocator,
        backend.storage(),
        failing_journal.journal(),
        &tracker,
        0,
    );
    var wrapped = notifier.storage();
    defer wrapped.deinit();

    var tx = try wrapped.begin();
    defer tx.end();

    try testing.expectError(Storage.Error.UnableToRecordWrite, wrapped.put("foo", .{ .string = "bar" }, .{ .expires_at = null }));
}

test "a read that finds no expired key does not increment the dirty count" {
    const testing = std.testing;

    var backend = DefaultStorage.init(testing.io, testing.allocator);
    var tracker = ChangeTracker.init(testing.io);
    var notifier = NotifierStorage.init(
        testing.allocator,
        backend.storage(),
        null,
        &tracker,
        0,
    );
    var wrapped = notifier.storage();
    defer wrapped.deinit();

    var tx = try wrapped.begin();
    defer tx.end();

    _ = try wrapped.put("foo", .{ .string = "bar" }, .{ .expires_at = null });
    try testing.expectEqual(1, tracker._dirty.load(.monotonic));

    _ = try wrapped.get("foo");

    try testing.expectEqual(1, tracker._dirty.load(.monotonic));
}

const RecordingJournal = struct {
    last_event: ?persistence.JournalPersistence.WriteEvent = null,

    const journal_vtable: persistence.JournalPersistence.VTable = .{
        .onWrite = onWrite,
        .flush = flush,
        .bgRewrite = bgRewrite,
        .finishRewrite = finishRewrite,
        .deinit = journalDeinit,
    };

    fn journal(self: *RecordingJournal) persistence.JournalPersistence {
        return .{ .ptr = self, .vtable = &journal_vtable };
    }

    fn onWrite(ptr: *anyopaque, event: persistence.JournalPersistence.WriteEvent) persistence.JournalPersistence.Error!void {
        const self: *RecordingJournal = @ptrCast(@alignCast(ptr));
        self.last_event = event;
    }

    fn flush(_: *anyopaque, _: i64) persistence.JournalPersistence.Error!void {}
    fn bgRewrite(_: *anyopaque) persistence.JournalPersistence.Error!void {}
    fn finishRewrite(_: *anyopaque, _: bool) persistence.JournalPersistence.Error!void {}
    fn journalDeinit(_: *anyopaque) persistence.JournalPersistence.Error!void {}
};

test "KEEPTTL over an existing expiry journals the existing absolute expiry" {
    const testing = std.testing;

    var backend = DefaultStorage.init(testing.io, testing.allocator);
    var tracker = ChangeTracker.init(testing.io);
    var recording_journal = RecordingJournal{};
    var notifier = NotifierStorage.init(
        testing.allocator,
        backend.storage(),
        recording_journal.journal(),
        &tracker,
        0,
    );
    var wrapped = notifier.storage();
    defer wrapped.deinit();

    var tx = try wrapped.begin();
    defer tx.end();

    const expires_at = time.nowMs(testing.io) + 100_000;
    _ = try wrapped.put("k", .{ .string = "v1" }, .{ .expires_at = expires_at });
    _ = try wrapped.put("k", .{ .string = "v2" }, .{ .expires_at = null, .keepttl = true });

    switch (recording_journal.last_event.?) {
        .put => |put_event| try testing.expectEqual(expires_at, put_event.expires_at),
        else => return error.TestUnexpectedResult,
    }
}
