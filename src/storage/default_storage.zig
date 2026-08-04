const std = @import("std");
const Storage = @import("interface.zig");
const entry = @import("../entry.zig");
const object = @import("../object.zig");
const time = @import("../time.zig");
const helpers = @import("../helpers.zig");

const DefaultStorage = @This();

// Each entry stores an expiration-list index even when it is `null`; see
// `entry.Object.exp_index`. On this 64-bit target the value is 32 bytes. This
// is only the map value: `StringHashMap` also stores the key slice, metadata,
// and unused capacity required by its load factor.
const EntryObjectMap = std.StringHashMap(entry.Object);

// An expiration record is exactly 24 bytes on this 64-bit target: a 16-byte
// key slice (pointer + length) and an 8-byte millisecond timestamp. `ArrayList`
// allocates by capacity, so unused reserved slots consume the same 24 bytes.
// Only keys with an expiration need an entry in this list.
const Expirables = std.ArrayList(entry.ObjectExpiration);

_allocator: std.mem.Allocator,
_io: std.Io,
_mutex: std.Io.Mutex = .init,
_entry_map: EntryObjectMap,
_expirables: Expirables,

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

pub fn storage(self: *DefaultStorage) Storage {
    return .{
        .ptr = self,
        .vtable = &vtable,
        ._io = self._io,
        ._mutex = &self._mutex,
    };
}

pub fn init(
    io: std.Io,
    allocator: std.mem.Allocator,
) DefaultStorage {
    return .{
        ._allocator = allocator,
        ._io = io,
        ._entry_map = EntryObjectMap.init(allocator),
        ._expirables = .empty,
    };
}

pub fn begin(ptr: *anyopaque) Storage.Error!Storage.Tx {
    var self: *DefaultStorage = @ptrCast(@alignCast(ptr));
    self._mutex.lock(self._io) catch return Storage.Error.TxCancelled;

    return Storage.Tx{
        ._io = self._io,
        ._mutex = &self._mutex,
    };
}

pub fn deinit(ptr: *anyopaque) void {
    const self: *DefaultStorage = @ptrCast(@alignCast(ptr));
    // This is the only place in storage that will directly use lock
    // We are locking the entire duration of all the items
    // This is fine since deinit onlly triggers when a storage is shutting down and
    // we wont be accepting anymore instructions at that point anyway
    self._mutex.lockUncancelable(self._io);
    defer self._mutex.unlock(self._io);

    var iterator = self._entry_map.iterator();

    while (iterator.next()) |item| {
        self._allocator.free(item.key_ptr.*);

        switch (item.value_ptr.value) {
            .string => |value| self._allocator.free(value),
            // TODO: Free all the variants
        }
    }
    self._entry_map.deinit();

    // NOTE: `key` field is owned by the `_entry_map` and will be freed by `_entry_map` . No need to double free it here.
    // `expires_at` is a plain value so no manual memory allocation happened. So no need to free it also.
    self._expirables.deinit(self._allocator);
    return;
}

// NOTE: `get` can silently remove `key` as a side effect (lazy expiration,
// below), but that removal is not observable from this function's return
// value alone. Any future wrapper that needs to observe every mutation
// (e.g. a persistence layer notifying RDB/AOF listeners) must not call this
// `get` directly for that purpose — it should route through the
// already-observable `removeIfExpired` first, then delegate the plain
// lookup to this `get`, so the lazy-expiration delete goes through the same
// notification path a `DEL` would.
pub fn get(ptr: *anyopaque, key: []const u8) Storage.Error!?entry.Object {
    const self: *DefaultStorage = @ptrCast(@alignCast(ptr));

    const is_removed = removeByKey(self, key, .expired_only) catch return Storage.Error.UnableToExpire;
    if (is_removed) {
        return null;
    }

    const value = self._entry_map.get(key) orelse return null;

    return value;
}

pub fn put(ptr: *anyopaque, key: []const u8, value: object.Object, options: Storage.PutOptions) Storage.Error!entry.Object {
    const self: *DefaultStorage = @ptrCast(@alignCast(ptr));
    const string_value = switch (value) {
        .string => |string| string,
    };

    if (self._entry_map.getPtr(key)) |existing| {
        const owned_value = try self._allocator.dupe(u8, string_value);
        errdefer self._allocator.free(owned_value);

        const old_value = existing.value;

        // no expiration set and no existing expiration
        // only update if keepttl is false
        if (options.expires_at == null and existing.exp_index != null and !options.keepttl) {
            try swapRemoveExpiration(self, existing);
            existing.exp_index = null;
        }

        //NOTE: we dont need to handle expiration set and existing expiration since it is invalid option stacking and
        //it should be handled at the set commander validation layer

        // update if expiration set and existing expiration
        if (options.expires_at != null and existing.exp_index != null) {
            const last_index = self._expirables.items.len - 1;
            if (existing.exp_index.? > last_index) {
                unreachable;
            }

            self._expirables.items[existing.exp_index.?].expires_at = options.expires_at.?;
        }

        // Append new if expiration set but no existing expiration
        if (options.expires_at != null and existing.exp_index == null) {
            const stored_key_ptr = self._entry_map.getKeyPtr(key) orelse unreachable;
            const stored_key = stored_key_ptr.*;

            self._expirables.append(self._allocator, .{
                .key = stored_key,
                .expires_at = options.expires_at.?,
            }) catch return Storage.Error.OutOfMemory;

            const index = self._expirables.items.len - 1;
            existing.exp_index = index;
        }

        // TODO: Handle all types
        // NOTE: Setting map only after all the fallible work to make sure that allocation failure does not cause corruption on existing value.
        existing.value = .{ .string = owned_value };

        self._allocator.free(old_value.string);
        return existing.*;
    }

    const owned_key = try self._allocator.dupe(u8, key);
    errdefer self._allocator.free(owned_key);

    const owned_value = try self._allocator.dupe(u8, string_value);
    errdefer self._allocator.free(owned_value);

    var entry_object: entry.Object = .{
        .value = .{ .string = owned_value },
        .exp_index = null,
    };

    if (options.expires_at) |expires_ms| {
        self._expirables.append(self._allocator, .{ .key = owned_key, .expires_at = expires_ms }) catch return Storage.Error.OutOfMemory;
        errdefer _ = self._expirables.pop();

        const index = self._expirables.items.len - 1;
        entry_object.exp_index = index;
    }

    self._entry_map.put(owned_key, entry_object) catch return Storage.Error.OutOfMemory;

    return entry_object;
}

pub fn remove(ptr: *anyopaque, key: []const u8) Storage.Error!void {
    const self: *DefaultStorage = @ptrCast(@alignCast(ptr));
    _ = try removeByKey(self, key, .unconditional);
    return;
}

pub fn removeIfExpired(ptr: *anyopaque, key: []const u8) Storage.Error!bool {
    const self: *DefaultStorage = @ptrCast(@alignCast(ptr));
    return try removeByKey(self, key, .expired_only);
}

pub fn getExp(_: *anyopaque, _: []const u8) Storage.Error!?entry.ObjectExpiration {
    return null;
}

pub fn setExp(_: *anyopaque, _: []const u8, _: ?time.UnixMs) Storage.Error!entry.ObjectExpiration {
    return entry.ObjectExpiration{
        .key = "foo",
        .expires_at = 1785000509089,
    };
}

pub fn tryExpireRandom(ptr: *anyopaque) Storage.Error!?[]const u8 {
    const self: *DefaultStorage = @ptrCast(@alignCast(ptr));
    if (self._expirables.items.len == 0) {
        return null;
    }

    const last_index = self._expirables.items.len - 1;
    const random_index = helpers.random(self._io, 0, last_index);

    // This could be unnecessary since random could actually guaranteed valid number between min and max
    // TODO: Remove this if we are sure to trust random
    if (random_index > last_index) {
        return Storage.Error.InvalidIndex;
    }

    const key = self._expirables.items[random_index].key;

    // `removeByKey` frees the map's copy of `key` on removal, so we must dupe
    // it *before* calling `removeByKey`, or the slice we'd return would be
    // dangling. Caller owns and must free `owned_key`.
    const owned_key = try self._allocator.dupe(u8, key);
    errdefer self._allocator.free(owned_key);

    const was_removed = try self.removeByKey(key, .expired_only);
    if (!was_removed) {
        self._allocator.free(owned_key);
        return null;
    }

    return owned_key;
}

pub fn getExpirableCount(ptr: *anyopaque) u32 {
    const self: *DefaultStorage = @ptrCast(@alignCast(ptr));
    return @intCast(self._expirables.items.len);
}

pub fn clearExp(_: *anyopaque, _: []const u8) Storage.Error!void {
    return;
}

pub fn forEach(_: *anyopaque, _: *anyopaque, _: *const fn (ctx: *anyopaque, key: []const u8, value: object.Object, exp: ?time.UnixMs) anyerror!void) Storage.Error!void {
    return;
}

pub fn size(ptr: *anyopaque) u32 {
    const self: *DefaultStorage = @ptrCast(@alignCast(ptr));
    return @intCast(self._entry_map.count());
}

// TODO: The only reason we return bool from this function is to support get method
// Find a way to support get method without exposing bool
fn removeByKey(self: *DefaultStorage, key: []const u8, mode: Storage.RemovalMode) !bool {
    if (self._entry_map.getPtr(key)) |entry_object| {
        if (entry_object.exp_index) |exp_index| {
            const index = exp_index;
            const last_index = self._expirables.items.len - 1;

            if (index < 0 or index > last_index) unreachable;

            const expirable = self._expirables.items[index];

            const is_expired = time.isPastTime(self._io, expirable.expires_at);
            const force_remove = mode == .unconditional;

            if (is_expired or force_remove) {
                try swapRemoveExpiration(self, entry_object);

                const removed = self._entry_map.fetchRemove(key) orelse unreachable;
                self._allocator.free(removed.key);

                switch (removed.value.value) {
                    .string => |str| self._allocator.free(str),
                }

                return true;
            }
        }
    }

    return false;
}

// Move the last item to index and overwrite it and then pop the last item hole
// NOTE: This is not a actual swap but rather make the hole and pop it
fn swapRemoveExpiration(self: *DefaultStorage, entry_object: *entry.Object) !void {
    const index = entry_object.exp_index orelse return;
    const last_index = self._expirables.items.len - 1;

    // If we have invalid index, that means our bookkeeping is broken
    if (index < 0 or index > last_index) unreachable;

    if (index != last_index) {
        const moved = self._expirables.items[last_index];
        self._expirables.items[index] = moved;

        const moved_entry = self._entry_map.getPtr(moved.key) orelse unreachable;
        moved_entry.exp_index = index;
    }

    _ = self._expirables.pop();
    entry_object.exp_index = null;
}

test "tryExpireRandom returns null when no entries have an expiration" {
    const testing = std.testing;

    var backend = DefaultStorage.init(testing.io, testing.allocator);
    var backend_storage = backend.storage();
    defer backend_storage.deinit();

    var tx = try backend_storage.begin();
    defer tx.end();

    try testing.expect(try backend_storage.tryExpireRandom() == null);
}

test "tryExpireRandom returns an owned copy of the removed key" {
    const testing = std.testing;

    var backend = DefaultStorage.init(testing.io, testing.allocator);
    var backend_storage = backend.storage();
    defer backend_storage.deinit();

    var tx = try backend_storage.begin();
    defer tx.end();

    _ = try backend_storage.put("expiring", .{ .string = "value" }, .{
        .expires_at = time.nowMs(testing.io) - 1,
    });

    const removed_key = try backend_storage.tryExpireRandom() orelse return error.TestUnexpectedResult;
    defer testing.allocator.free(removed_key);

    try testing.expectEqualStrings("expiring", removed_key);
    try testing.expectEqual(0, backend_storage.size());
}

test "size counts all stored entries, not just expirable ones" {
    const testing = std.testing;

    var backend = DefaultStorage.init(testing.io, testing.allocator);
    var backend_storage = backend.storage();
    defer backend_storage.deinit();

    var tx = try backend_storage.begin();
    defer tx.end();

    _ = try backend_storage.put("persistent", .{ .string = "value" }, .{ .expires_at = null });
    _ = try backend_storage.put("expiring", .{ .string = "value" }, .{
        .expires_at = time.nowMs(testing.io) + 1_000,
    });

    try testing.expectEqual(2, backend_storage.size());
}

test "removing an expiration keeps the moved entry index valid" {
    const testing = std.testing;

    var backend = DefaultStorage.init(testing.io, testing.allocator);
    var backend_storage = backend.storage();
    defer backend_storage.deinit();

    var tx = try backend_storage.begin();
    defer tx.end();

    const expires_at = time.nowMs(testing.io) + 60_000;
    _ = try backend_storage.put("first", .{ .string = "one" }, .{ .expires_at = expires_at });
    _ = try backend_storage.put("second", .{ .string = "two" }, .{ .expires_at = expires_at });

    try backend_storage.remove("first");
    _ = try backend_storage.put("second", .{ .string = "updated" }, .{ .expires_at = expires_at + 1 });

    const second = try backend_storage.get("second") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("updated", second.value.string);
    try testing.expectEqual(1, backend_storage.size());
    try testing.expectEqual(1, backend_storage.getExpirableCount());
}

test "expired entries are removed when read and no longer counted" {
    const testing = std.testing;

    var backend = DefaultStorage.init(testing.io, testing.allocator);
    var backend_storage = backend.storage();
    defer backend_storage.deinit();

    var tx = try backend_storage.begin();
    defer tx.end();

    _ = try backend_storage.put("expired", .{ .string = "value" }, .{
        .expires_at = time.nowMs(testing.io) - 1,
    });

    try testing.expect(try backend_storage.get("expired") == null);
    try testing.expectEqual(0, backend_storage.size());
    try testing.expectEqual(0, backend_storage.getExpirableCount());
}

test "transactions release the storage mutex" {
    const testing = std.testing;

    var backend = DefaultStorage.init(testing.io, testing.allocator);
    var backend_storage = backend.storage();
    defer backend_storage.deinit();

    var first = try backend_storage.begin();
    first.end();

    var second = try backend_storage.begin();
    second.end();
}

test "active expiration sampling releases the storage mutex" {
    const testing = std.testing;

    var backend = DefaultStorage.init(testing.io, testing.allocator);
    var backend_storage = backend.storage();
    defer backend_storage.deinit();

    var put_tx = try backend_storage.begin();
    _ = try backend_storage.put("expiring", .{ .string = "value" }, .{
        .expires_at = time.nowMs(testing.io) + 1_000,
    });
    put_tx.end();

    var expiration_tx = try backend_storage.begin();
    if (try backend_storage.tryExpireRandom()) |key| testing.allocator.free(key);
    expiration_tx.end();

    var next_tx = try backend_storage.begin();
    next_tx.end();
}
