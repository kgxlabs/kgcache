const std = @import("std");
const Storage = @import("interface.zig");
const entry = @import("../entry.zig");
const object = @import("../object.zig");
const time = @import("../time.zig");
const helpers = @import("../helpers.zig");

const DefaultStorage = @This();

// Each entry stores an expiration-list index even when it is `null`; see
// `entry.Object.exp_index`. On this 64-bit target the value is 24 bytes. This
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
    .tryExpireRandom = tryExpireRandom,
    .deinit = deinit,
};

pub fn storage(self: *DefaultStorage) Storage {
    return .{
        .ptr = self,
        .vtable = &vtable,
        ._io = self._io,
        ._mutex = self._mutex,
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
        ._storage = self.storage(),
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
            const last_index: usize = @intCast(self._expirables.items.len - 1);
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

            const index: usize = @intCast(self._expirables.items.len - 1);
            existing.exp_index = @intCast(index);
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

        const index: usize = @intCast(self._expirables.items.len - 1);
        entry_object.exp_index = @intCast(index);
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

pub fn tryExpireRandom(ptr: *anyopaque) Storage.Error!bool {
    const self: *DefaultStorage = @ptrCast(@alignCast(ptr));
    const last_index = self._expirables.items.len - 1;
    const random_index = helpers.random(self._io, 0, last_index);

    // This could be unnecessary since random could actually guaranteed valid number between min and max
    // TODO: Remove this if we are sure to trust random
    if (random_index < 0 or random_index > last_index) {
        return Storage.Error.InvalidIndex;
    }

    const item = self._expirables.items[random_index];
    return try self.removeByKey(item.key, .expired_only);
}

pub fn clearExp(_: *anyopaque, _: []const u8) Storage.Error!void {
    return;
}

// TODO: The only reason we return bool from this function is to support get method
// Find a way to support get method without exposing bool
fn removeByKey(self: *DefaultStorage, key: []const u8, mode: Storage.RemovalMode) !bool {
    if (self._entry_map.getPtr(key)) |entry_object| {
        if (entry_object.exp_index) |exp_index| {
            const index: usize = @intCast(exp_index);
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
    const index: usize = @intCast(entry_object.exp_index orelse return);
    const last_index = self._expirables.items.len - 1;

    // If we have invalid index, that means our bookkeeping is broken
    if (index < 0 or index > last_index) unreachable;

    if (index != last_index) {
        const moved = self._expirables.items[last_index];
        self._expirables.items[index] = moved;

        const moved_entry = self._entry_map.getPtr(moved.key) orelse unreachable;
        moved_entry.exp_index = @intCast(index);
    }

    _ = self._expirables.pop();
    entry_object.exp_index = null;
}
