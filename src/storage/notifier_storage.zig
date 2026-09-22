// NOTE: ============================================================================
// AOF WRITE SAFETY RULES
// ============================================================================
// AOF-backed changes must follow one flow:
// 1. The AOF record must be prepared before storage changes.
// 2. The record must be aborted if the storage change fails.
// 3. The record must be published after the storage change succeeds.
// Preparation must reserve everything needed by publish.
// A failed flush must keep the published record for retry.
// ============================================================================

const std = @import("std");
const persistence = @import("../persistence.zig");
const Storage = @import("interface.zig");
const entry = @import("../entry.zig");
const object = @import("../object.zig");
const time = @import("../time.zig");
const helpers = @import("../helpers.zig");
const PersistenceState = @import("../persistence_state.zig");
const Config = @import("../config.zig");
const DefaultStorage = @import("default_storage.zig");
const Lock = @import("../lock.zig");
const Store = @import("../store/interface.zig");

const NotifierStorage = @This();

_io: std.Io,
_allocator: std.mem.Allocator,
_inner: Storage,
// AOF is optional: write-log notifications are only sent if a journal backend is configured.
// KGC snapshotting is not routed through here: it needs a `Storage` handle to enumerate
// every key, not a per-write hook, so it lives at the `Store` level instead (see MemoryStore).
_aof: ?persistence.JournalPersistence,
// Shared across every db's NotifierStorage: the dirty count is process-wide, not per-database.
_persistence_state: *PersistenceState,
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
    .sampleExpirableKey = sampleExpirableKey,
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
        ._lock = self._inner._lock,
    };
}

pub fn init(
    io: std.Io,
    allocator: std.mem.Allocator,
    inner: Storage,
    aof: ?persistence.JournalPersistence,
    persistence_state: *PersistenceState,
    db_index: u32,
) NotifierStorage {
    return .{
        ._io = io,
        ._allocator = allocator,
        ._inner = inner,
        ._aof = aof,
        ._persistence_state = persistence_state,
        ._db_index = db_index,
    };
}

pub fn begin(ptr: *anyopaque) anyerror!Storage.Tx {
    var self: *NotifierStorage = @ptrCast(@alignCast(ptr));
    return self._inner.begin();
}

// TODO: Figure out do we need to clean up our own or not here
pub fn deinit(ptr: *anyopaque) void {
    const self: *NotifierStorage = @ptrCast(@alignCast(ptr));
    return self._inner.deinit();
}

pub fn get(ptr: *anyopaque, key: []const u8) anyerror!?entry.Object {
    const self: *NotifierStorage = @ptrCast(@alignCast(ptr));
    if (self._aof) |aof| {
        const maybe_exp = try self._inner.getExp(key);
        if (maybe_exp) |exp| {
            if (time.isPastTime(self._inner._io, exp.expires_at)) {
                var aof_tx = try aof.begin();
                defer aof_tx.end();

                var record = try aof.prepareRecord(.{
                    .remove = .{ .db_index = self._db_index, .key = key },
                });
                errdefer record.abort();

                const is_removed = try self._inner.removeIfExpired(key);
                if (is_removed) {
                    self._persistence_state.recordChange();
                    record.publish();
                    try aof.flush(time.nowMs(self._io), .{ .mode = .if_required });
                    return null;
                }

                record.abort();
            }
        }

        return self._inner.get(key);
    }

    const is_removed = try self._inner.removeIfExpired(key);
    if (is_removed) self._persistence_state.recordChange();
    return self._inner.get(key);
}

pub fn put(ptr: *anyopaque, key: []const u8, value: object.Object, options: Storage.PutOptions) anyerror!entry.Object {
    const self: *NotifierStorage = @ptrCast(@alignCast(ptr));

    if (self._aof) |aof| {
        // Use the explicit expiration, or preserve the current one for KEEPTTL.
        const expires_at: ?time.UnixMs = if (options.expires_at) |exp|
            exp
        else if (options.keepttl) blk: {
            const maybe_exp = try self._inner.getExp(key);
            break :blk if (maybe_exp) |exp| exp.expires_at else null;
        } else null;

        var aof_tx = try aof.begin();
        defer aof_tx.end();

        var record = try aof.prepareRecord(.{ .put = .{
            .db_index = self._db_index,
            .key = key,
            .value = value,
            .expires_at = expires_at,
        } });
        errdefer record.abort();

        const result = try self._inner.put(key, value, options);
        self._persistence_state.recordChange();
        record.publish();
        try aof.flush(time.nowMs(self._io), .{ .mode = .if_required });
        return result;
    }

    const result = try self._inner.put(key, value, options);
    self._persistence_state.recordChange();
    return result;
}

// remove returns void meaning it cannot say if anything was actually deleted.
// DEL for a missing key gets journaled too. DEL on missing key is idempotent on replay. We have to accept this
// TODO: make report whether or not if removed something or not.
pub fn remove(ptr: *anyopaque, key: []const u8) anyerror!void {
    const self: *NotifierStorage = @ptrCast(@alignCast(ptr));

    if (self._aof) |aof| {
        var aof_tx = try aof.begin();
        defer aof_tx.end();

        var record = try aof.prepareRecord(.{
            .remove = .{ .db_index = self._db_index, .key = key },
        });
        errdefer record.abort();

        try self._inner.remove(key);
        self._persistence_state.recordChange();
        record.publish();
        try aof.flush(time.nowMs(self._io), .{ .mode = .if_required });
        return;
    }

    try self._inner.remove(key);
    self._persistence_state.recordChange();
}

pub fn removeIfExpired(ptr: *anyopaque, key: []const u8) anyerror!bool {
    const self: *NotifierStorage = @ptrCast(@alignCast(ptr));
    return self._inner.removeIfExpired(key);
}

pub fn getExp(ptr: *anyopaque, key: []const u8) anyerror!?entry.ObjectExpiration {
    const self: *NotifierStorage = @ptrCast(@alignCast(ptr));
    return self._inner.getExp(key);
}

// TODO: setExp doesn't journal. Harmless today since no command reaches this
// without also writing a value; EXPIRE/PERSIST/GETEX will need to journal
// from here once they exist.
pub fn setExp(ptr: *anyopaque, key: []const u8, exp: ?time.UnixMs) anyerror!entry.ObjectExpiration {
    const self: *NotifierStorage = @ptrCast(@alignCast(ptr));
    return self._inner.setExp(key, exp);
}

pub fn tryExpireRandom(ptr: *anyopaque) anyerror!?[]const u8 {
    const self: *NotifierStorage = @ptrCast(@alignCast(ptr));

    if (self._aof) |aof| {
        const maybe_key = try self._inner.sampleExpirableKey();
        const key = maybe_key orelse return null;
        errdefer self._allocator.free(key);

        var aof_tx = try aof.begin();
        defer aof_tx.end();

        var record = try aof.prepareRecord(.{
            .remove = .{
                .key = key,
                .db_index = self._db_index,
            },
        });
        errdefer record.abort();

        const is_removed = try self._inner.removeIfExpired(key);
        if (!is_removed) {
            record.abort();
            self._allocator.free(key);
            return null;
        }

        self._persistence_state.recordChange();
        record.publish();
        try aof.flush(time.nowMs(self._io), .{ .mode = .if_required });
        return key;
    }

    const maybe_key = try self._inner.tryExpireRandom();
    if (maybe_key != null) self._persistence_state.recordChange();
    return maybe_key;
}

pub fn getExpirableCount(ptr: *anyopaque) u32 {
    const self: *NotifierStorage = @ptrCast(@alignCast(ptr));
    return self._inner.getExpirableCount();
}

pub fn sampleExpirableKey(ptr: *anyopaque) anyerror!?[]const u8 {
    const self: *NotifierStorage = @ptrCast(@alignCast(ptr));
    return self._inner.sampleExpirableKey();
}

// TODO: same gap as setExp. PERSIST will need to journal from here.
pub fn clearExp(ptr: *anyopaque, key: []const u8) anyerror!void {
    const self: *NotifierStorage = @ptrCast(@alignCast(ptr));
    return self._inner.clearExp(key);
}

pub fn size(ptr: *anyopaque) u32 {
    const self: *NotifierStorage = @ptrCast(@alignCast(ptr));
    return self._inner.size();
}

pub fn forEach(ptr: *anyopaque, ctx: *anyopaque, visit: *const fn (ctx: *anyopaque, key: []const u8, value: object.Object, exp: ?time.UnixMs) anyerror!void) anyerror!void {
    const self: *NotifierStorage = @ptrCast(@alignCast(ptr));
    return self._inner.forEach(ctx, visit);
}

test "put increments the persistence change count" {
    const testing = std.testing;

    var backend = DefaultStorage.init(testing.io, testing.allocator);
    var persistence_state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });
    var notifier = NotifierStorage.init(testing.io, testing.allocator, backend.storage(), null, &persistence_state, 0);
    var wrapped = notifier.storage();
    defer wrapped.deinit();

    var tx = try wrapped.begin();
    defer tx.end();

    _ = try wrapped.put("foo", .{ .string = "bar" }, .{ .expires_at = null });

    try testing.expectEqual(1, persistence_state.captureSnapshotChangeCount());
}

test "remove increments the persistence change count" {
    const testing = std.testing;

    var backend = DefaultStorage.init(testing.io, testing.allocator);
    var persistence_state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });
    var notifier = NotifierStorage.init(testing.io, testing.allocator, backend.storage(), null, &persistence_state, 0);
    var wrapped = notifier.storage();
    defer wrapped.deinit();

    var tx = try wrapped.begin();
    defer tx.end();

    _ = try wrapped.put("foo", .{ .string = "bar" }, .{ .expires_at = null });
    try wrapped.remove("foo");

    try testing.expectEqual(2, persistence_state.captureSnapshotChangeCount());
}

test "a lazy-expiration removal during get increments the persistence change count" {
    const testing = std.testing;

    var backend = DefaultStorage.init(testing.io, testing.allocator);
    var persistence_state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });
    var notifier = NotifierStorage.init(testing.io, testing.allocator, backend.storage(), null, &persistence_state, 0);
    var wrapped = notifier.storage();
    defer wrapped.deinit();

    var tx = try wrapped.begin();
    defer tx.end();

    _ = try wrapped.put("expired", .{ .string = "value" }, .{
        .expires_at = time.nowMs(testing.io) - 1,
    });
    try testing.expectEqual(1, persistence_state.captureSnapshotChangeCount());

    try testing.expect(try wrapped.get("expired") == null);

    try testing.expectEqual(2, persistence_state.captureSnapshotChangeCount());
}

const FailingJournal = struct {
    lock: Lock,

    fn init(io: std.Io) FailingJournal {
        return .{ .lock = Lock.init(io) };
    }

    const journal_vtable: persistence.JournalPersistence.VTable = .{
        .prepareRecord = prepareRecord,
        .flush = flush,
        .bgRewrite = bgRewrite,
        .dueForRewrite = dueForRewrite,
        .finishRewrite = finishRewrite,
        .beginLoading = beginLoading,
        .endLoading = endLoading,
        .reconcile = reconcile,
        .deinit = journalDeinit,
    };

    fn journal(self: *FailingJournal) persistence.JournalPersistence {
        return .{ .ptr = self, .vtable = &journal_vtable, ._lock = &self.lock };
    }

    fn prepareRecord(_: *anyopaque, _: persistence.JournalPersistence.WriteEvent) anyerror!persistence.JournalPersistence.Record {
        return error.TestPrepareRecord;
    }

    fn flush(_: *anyopaque, _: i64, _: persistence.JournalPersistence.FlushOptions) anyerror!void {}
    fn bgRewrite(_: *anyopaque, _: []const Storage, _: Store.TriggerOrigin) anyerror!PersistenceState.BackgroundStartOutcome {
        return .started;
    }
    fn dueForRewrite(_: *anyopaque, _: Config) anyerror!bool {
        return false;
    }
    fn finishRewrite(_: *anyopaque, _: PersistenceState.ReapResult) anyerror!void {}
    fn beginLoading(_: *anyopaque) void {}
    fn endLoading(_: *anyopaque) void {}
    fn reconcile(_: *anyopaque, _: std.Io, _: std.mem.Allocator, _: std.Io.Dir, _: []const u8, _: ?persistence.AofManifest.Manifest) anyerror!void {}
    fn journalDeinit(_: *anyopaque) anyerror!void {}
};

test "a journal that fails to record a write fails the put" {
    const testing = std.testing;

    var backend = DefaultStorage.init(testing.io, testing.allocator);
    var persistence_state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });
    var failing_journal = FailingJournal.init(testing.io);
    var notifier = NotifierStorage.init(
        testing.io,
        testing.allocator,
        backend.storage(),
        failing_journal.journal(),
        &persistence_state,
        0,
    );
    var wrapped = notifier.storage();
    defer wrapped.deinit();

    var tx = try wrapped.begin();
    defer tx.end();

    try testing.expectError(error.TestPrepareRecord, wrapped.put("foo", .{ .string = "bar" }, .{ .expires_at = null }));
    try testing.expect(try wrapped.get("foo") == null);
    try testing.expectEqual(0, persistence_state.captureSnapshotChangeCount());
}

test "a journal preparation failure leaves a removed key unchanged" {
    const testing = std.testing;

    var backend = DefaultStorage.init(testing.io, testing.allocator);
    var inner = backend.storage();
    {
        var tx = try inner.begin();
        defer tx.end();
        _ = try inner.put("foo", .{ .string = "bar" }, .{ .expires_at = null });
    }

    var persistence_state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });
    var failing_journal = FailingJournal.init(testing.io);
    var notifier = NotifierStorage.init(testing.io, testing.allocator, inner, failing_journal.journal(), &persistence_state, 0);
    var wrapped = notifier.storage();
    defer wrapped.deinit();

    var tx = try wrapped.begin();
    defer tx.end();

    try testing.expectError(error.TestPrepareRecord, wrapped.remove("foo"));
    try testing.expect((try wrapped.get("foo")) != null);
    try testing.expectEqual(0, persistence_state.captureSnapshotChangeCount());
}

test "a journal preparation failure leaves a lazy-expired key stored" {
    const testing = std.testing;

    var backend = DefaultStorage.init(testing.io, testing.allocator);
    var inner = backend.storage();
    {
        var tx = try inner.begin();
        defer tx.end();
        _ = try inner.put("expired", .{ .string = "value" }, .{
            .expires_at = time.nowMs(testing.io) - 1,
        });
    }

    var persistence_state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });
    var failing_journal = FailingJournal.init(testing.io);
    var notifier = NotifierStorage.init(testing.io, testing.allocator, inner, failing_journal.journal(), &persistence_state, 0);
    var wrapped = notifier.storage();
    defer wrapped.deinit();

    var tx = try wrapped.begin();
    defer tx.end();

    try testing.expectError(error.TestPrepareRecord, wrapped.get("expired"));
    try testing.expectEqual(1, wrapped.size());
    try testing.expectEqual(1, wrapped.getExpirableCount());
    try testing.expectEqual(0, persistence_state.captureSnapshotChangeCount());
}

test "a journal preparation failure leaves an active-expiration key stored" {
    const testing = std.testing;

    var backend = DefaultStorage.init(testing.io, testing.allocator);
    var inner = backend.storage();
    {
        var tx = try inner.begin();
        defer tx.end();
        _ = try inner.put("expired", .{ .string = "value" }, .{
            .expires_at = time.nowMs(testing.io) - 1,
        });
    }

    var persistence_state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });
    var failing_journal = FailingJournal.init(testing.io);
    var notifier = NotifierStorage.init(testing.io, testing.allocator, inner, failing_journal.journal(), &persistence_state, 0);
    var wrapped = notifier.storage();
    defer wrapped.deinit();

    var tx = try wrapped.begin();
    defer tx.end();

    try testing.expectError(error.TestPrepareRecord, wrapped.tryExpireRandom());
    try testing.expectEqual(1, wrapped.size());
    try testing.expectEqual(1, wrapped.getExpirableCount());
    try testing.expectEqual(0, persistence_state.captureSnapshotChangeCount());
}

test "a journal preparation failure leaves a lazily expired key unchanged" {
    const testing = std.testing;

    var backend = DefaultStorage.init(testing.io, testing.allocator);
    var inner = backend.storage();
    {
        var tx = try inner.begin();
        defer tx.end();
        _ = try inner.put("expired", .{ .string = "value" }, .{
            .expires_at = time.nowMs(testing.io) - 1,
        });
    }

    var persistence_state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });
    var failing_journal = FailingJournal.init(testing.io);
    var notifier = NotifierStorage.init(testing.io, testing.allocator, inner, failing_journal.journal(), &persistence_state, 0);
    var wrapped = notifier.storage();
    defer wrapped.deinit();

    var tx = try wrapped.begin();
    defer tx.end();

    try testing.expectError(error.TestPrepareRecord, wrapped.get("expired"));
    try testing.expectEqual(1, wrapped.size());
    try testing.expectEqual(1, wrapped.getExpirableCount());
    try testing.expectEqual(0, persistence_state.captureSnapshotChangeCount());
}

test "a journal preparation failure leaves an actively expired key unchanged" {
    const testing = std.testing;

    var backend = DefaultStorage.init(testing.io, testing.allocator);
    var inner = backend.storage();
    {
        var tx = try inner.begin();
        defer tx.end();
        _ = try inner.put("expired", .{ .string = "value" }, .{
            .expires_at = time.nowMs(testing.io) - 1,
        });
    }

    var persistence_state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });
    var failing_journal = FailingJournal.init(testing.io);
    var notifier = NotifierStorage.init(testing.io, testing.allocator, inner, failing_journal.journal(), &persistence_state, 0);
    var wrapped = notifier.storage();
    defer wrapped.deinit();

    var tx = try wrapped.begin();
    defer tx.end();

    try testing.expectError(error.TestPrepareRecord, wrapped.tryExpireRandom());
    try testing.expectEqual(1, wrapped.size());
    try testing.expectEqual(1, wrapped.getExpirableCount());
    try testing.expectEqual(0, persistence_state.captureSnapshotChangeCount());
}

test "a read that finds no expired key does not increment the dirty count" {
    const testing = std.testing;

    var backend = DefaultStorage.init(testing.io, testing.allocator);
    var persistence_state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });
    var notifier = NotifierStorage.init(
        testing.io,
        testing.allocator,
        backend.storage(),
        null,
        &persistence_state,
        0,
    );
    var wrapped = notifier.storage();
    defer wrapped.deinit();

    var tx = try wrapped.begin();
    defer tx.end();

    _ = try wrapped.put("foo", .{ .string = "bar" }, .{ .expires_at = null });
    try testing.expectEqual(1, persistence_state.captureSnapshotChangeCount());

    _ = try wrapped.get("foo");

    try testing.expectEqual(1, persistence_state.captureSnapshotChangeCount());
}

const RecordingJournal = struct {
    lock: Lock,
    last_event: ?persistence.JournalPersistence.WriteEvent = null,
    publish_count: usize = 0,
    flush_count: usize = 0,
    abort_count: usize = 0,
    published_at_flush: usize = 0,
    last_flush_mode: ?persistence.JournalPersistence.FlushMode = null,
    fail_flush: bool = false,

    fn init(io: std.Io) RecordingJournal {
        return .{ .lock = Lock.init(io) };
    }

    const journal_vtable: persistence.JournalPersistence.VTable = .{
        .prepareRecord = prepareRecord,
        .flush = flush,
        .bgRewrite = bgRewrite,
        .dueForRewrite = dueForRewrite,
        .finishRewrite = finishRewrite,
        .beginLoading = beginLoading,
        .endLoading = endLoading,
        .reconcile = reconcile,
        .deinit = journalDeinit,
    };

    fn journal(self: *RecordingJournal) persistence.JournalPersistence {
        return .{ .ptr = self, .vtable = &journal_vtable, ._lock = &self.lock };
    }

    fn publishRecord(ptr: *anyopaque, event: persistence.JournalPersistence.WriteEvent) void {
        const self: *RecordingJournal = @ptrCast(@alignCast(ptr));
        self.last_event = event;
        self.publish_count += 1;
    }

    fn prepareRecord(ptr: *anyopaque, event: persistence.JournalPersistence.WriteEvent) anyerror!persistence.JournalPersistence.Record {
        return persistence.JournalPersistence.Record.init(ptr, event, publishRecord, abortRecord);
    }

    fn abortRecord(ptr: *anyopaque, _: persistence.JournalPersistence.WriteEvent) void {
        const self: *RecordingJournal = @ptrCast(@alignCast(ptr));
        self.abort_count += 1;
    }

    fn flush(ptr: *anyopaque, _: i64, options: persistence.JournalPersistence.FlushOptions) anyerror!void {
        const self: *RecordingJournal = @ptrCast(@alignCast(ptr));
        self.flush_count += 1;
        self.published_at_flush = self.publish_count;
        self.last_flush_mode = options.mode;
        if (self.fail_flush) return error.TestFlushSource;
    }
    fn bgRewrite(_: *anyopaque, _: []const Storage, _: Store.TriggerOrigin) anyerror!PersistenceState.BackgroundStartOutcome {
        return .started;
    }
    fn dueForRewrite(_: *anyopaque, _: Config) anyerror!bool {
        return false;
    }
    fn finishRewrite(_: *anyopaque, _: PersistenceState.ReapResult) anyerror!void {}
    fn beginLoading(_: *anyopaque) void {}
    fn endLoading(_: *anyopaque) void {}
    fn reconcile(_: *anyopaque, _: std.Io, _: std.mem.Allocator, _: std.Io.Dir, _: []const u8, _: ?persistence.AofManifest.Manifest) anyerror!void {}
    fn journalDeinit(_: *anyopaque) anyerror!void {}
};

test "mutations request a required flush after publication and stay applied on flush failure" {
    const testing = std.testing;
    const Mutation = enum {
        put,
        remove,
        lazy_expiration,
        active_expiration,

        fn apply(self: @This(), wrapped: Storage) !void {
            switch (self) {
                .put => _ = try wrapped.put("foo", .{ .string = "bar" }, .{ .expires_at = null }),
                .remove => try wrapped.remove("foo"),
                .lazy_expiration => try testing.expect(try wrapped.get("foo") == null),
                .active_expiration => {
                    const removed_key = try wrapped.tryExpireRandom();
                    defer if (removed_key) |key| testing.allocator.free(key);
                    try testing.expect(removed_key != null);
                    try testing.expectEqualStrings("foo", removed_key.?);
                },
            }
        }
    };

    const mutations = [_]Mutation{ .put, .remove, .lazy_expiration, .active_expiration };
    for (mutations) |mutation| {
        for ([_]bool{ false, true }) |fail_flush| {
            var backend = DefaultStorage.init(testing.io, testing.allocator);
            const inner = backend.storage();
            var persistence_state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });
            var recording_journal = RecordingJournal.init(testing.io);
            recording_journal.fail_flush = fail_flush;
            var notifier = NotifierStorage.init(testing.io, testing.allocator, inner, recording_journal.journal(), &persistence_state, 0);
            const wrapped = notifier.storage();
            defer wrapped.deinit();

            var tx = try wrapped.begin();
            defer tx.end();

            const expires_at: ?time.UnixMs = switch (mutation) {
                .lazy_expiration, .active_expiration => time.nowMs(testing.io) - 1,
                .put, .remove => null,
            };
            _ = try inner.put("foo", .{ .string = "old" }, .{ .expires_at = expires_at });

            if (fail_flush) {
                try testing.expectError(error.TestFlushSource, mutation.apply(wrapped));
            } else {
                try mutation.apply(wrapped);
            }

            try testing.expectEqual(1, persistence_state.captureSnapshotChangeCount());
            try testing.expectEqual(1, recording_journal.publish_count);
            try testing.expectEqual(1, recording_journal.flush_count);
            try testing.expectEqual(1, recording_journal.published_at_flush);
            try testing.expectEqual(0, recording_journal.abort_count);
            try testing.expectEqual(.if_required, recording_journal.last_flush_mode.?);

            if (mutation == .put) {
                const stored = (try inner.get("foo")).?;
                try testing.expectEqualStrings("bar", stored.value.string);
            } else {
                try testing.expectEqual(0, inner.size());
                try testing.expectEqual(0, inner.getExpirableCount());
            }
        }
    }
}

test "KEEPTTL over an existing expiry journals the existing absolute expiry" {
    const testing = std.testing;

    var backend = DefaultStorage.init(testing.io, testing.allocator);
    var persistence_state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });
    var recording_journal = RecordingJournal.init(testing.io);
    var notifier = NotifierStorage.init(
        testing.io,
        testing.allocator,
        backend.storage(),
        recording_journal.journal(),
        &persistence_state,
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

test "remove journals a DEL" {
    const testing = std.testing;

    var backend = DefaultStorage.init(testing.io, testing.allocator);
    var persistence_state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });
    var recording_journal = RecordingJournal.init(testing.io);
    var notifier = NotifierStorage.init(
        testing.io,
        testing.allocator,
        backend.storage(),
        recording_journal.journal(),
        &persistence_state,
        0,
    );
    var wrapped = notifier.storage();
    defer wrapped.deinit();

    var tx = try wrapped.begin();
    defer tx.end();

    _ = try wrapped.put("foo", .{ .string = "bar" }, .{ .expires_at = null });
    try wrapped.remove("foo");

    switch (recording_journal.last_event.?) {
        .remove => |remove_event| try testing.expectEqualStrings("foo", remove_event.key),
        else => return error.TestUnexpectedResult,
    }
}

test "an active-expiration removal journals a DEL and increments the dirty count" {
    const testing = std.testing;

    var backend = DefaultStorage.init(testing.io, testing.allocator);
    var persistence_state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });
    var recording_journal = RecordingJournal.init(testing.io);
    var notifier = NotifierStorage.init(
        testing.io,
        testing.allocator,
        backend.storage(),
        recording_journal.journal(),
        &persistence_state,
        0,
    );
    var wrapped = notifier.storage();
    defer wrapped.deinit();

    var tx = try wrapped.begin();
    defer tx.end();

    _ = try wrapped.put("expired", .{ .string = "value" }, .{
        .expires_at = time.nowMs(testing.io) - 1,
    });
    try testing.expectEqual(1, persistence_state.captureSnapshotChangeCount());

    const removed_key = try wrapped.tryExpireRandom();
    try testing.expect(removed_key != null);
    defer testing.allocator.free(removed_key.?);

    try testing.expectEqual(2, persistence_state.captureSnapshotChangeCount());

    switch (recording_journal.last_event.?) {
        .remove => |remove_event| try testing.expectEqualStrings("expired", remove_event.key),
        else => return error.TestUnexpectedResult,
    }
}

test "reading and sampling a live key do not publish or flush another record" {
    const testing = std.testing;

    var backend = DefaultStorage.init(testing.io, testing.allocator);
    var persistence_state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });
    var recording_journal = RecordingJournal.init(testing.io);
    var notifier = NotifierStorage.init(
        testing.io,
        testing.allocator,
        backend.storage(),
        recording_journal.journal(),
        &persistence_state,
        0,
    );
    var wrapped = notifier.storage();
    defer wrapped.deinit();

    var tx = try wrapped.begin();
    defer tx.end();

    _ = try wrapped.put("alive", .{ .string = "value" }, .{
        .expires_at = time.nowMs(testing.io) + 100_000,
    });
    try testing.expectEqual(1, persistence_state.captureSnapshotChangeCount());

    try testing.expect(try wrapped.get("alive") != null);
    const removed_key = try wrapped.tryExpireRandom();
    try testing.expect(removed_key == null);

    try testing.expectEqual(1, persistence_state.captureSnapshotChangeCount());
    try testing.expectEqual(1, recording_journal.publish_count);
    try testing.expectEqual(1, recording_journal.flush_count);
    switch (recording_journal.last_event.?) {
        .put => {},
        .remove => return error.TestUnexpectedResult,
    }
}
