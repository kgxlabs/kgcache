const std = @import("std");
const Storage = @import("interface.zig");
const entry = @import("../entry.zig");
const object = @import("../object.zig");

const DefaultStorage = @This();

const EntryObjectMap = std.StringHashMap(entry.Object);
const Expirables = std.ArrayList(entry.ObjectExpiration);

_allocator: std.mem.Allocator,
_entry_map: EntryObjectMap,
_expirables: Expirables,

const vtable: Storage.VTable = .{
    .get = get,
    .put = put,
    .remove = remove,
    .getExp = getExp,
    .setExp = setExp,
    .clearExp = clearExp,
    .deinit = deinit,
};

pub fn storage(self: *DefaultStorage) Storage {
    return .{
        .ptr = self,
        .vtable = &vtable,
    };
}

pub fn init(
    allocator: std.mem.Allocator,
) DefaultStorage {
    return .{
        ._allocator = allocator,
        ._entry_map = EntryObjectMap.init(allocator),
        ._expirables = .empty,
    };
}

pub fn deinit(ptr: *anyopaque) void {
    const self: *DefaultStorage = @ptrCast(@alignCast(ptr));
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
    const value = self._entry_map.get(key) orelse return null;
    return value;
}

pub fn put(ptr: *anyopaque, key: []const u8, value: object.Object, _: ?entry.ObjectExpirationMs) Storage.Error!entry.Object {
    const self: *DefaultStorage = @ptrCast(@alignCast(ptr));

    const string_value = switch (value) {
        .string => |string| string,
    };

    if (self._entry_map.getPtr(key)) |existing| {
        const owned_value = try self._allocator.dupe(u8, string_value);
        errdefer self._allocator.free(owned_value);

        const old_value = existing.value;
        // TODO: Handle all types
        existing.value = .{ .string = owned_value };

        self._allocator.free(old_value.string);
        return existing.*;
    }

    const owned_key = try self._allocator.dupe(u8, key);
    errdefer self._allocator.free(owned_key);

    const owned_value = try self._allocator.dupe(u8, string_value);
    errdefer self._allocator.free(owned_value);

    const entry_object: entry.Object = .{
        .value = .{
            .string = owned_value,
        },
        .exp_index = null,
    };

    self._entry_map.put(owned_key, entry_object) catch return Storage.Error.OutOfMemory;

    return entry_object;
}

pub fn remove(_: *anyopaque, _: []const u8) Storage.Error!void {
    return;
}

pub fn getExp(_: *anyopaque, _: []const u8) Storage.Error!?entry.ObjectExpiration {
    return null;
}

pub fn setExp(_: *anyopaque, _: []const u8, _: ?entry.ObjectExpirationMs) Storage.Error!entry.ObjectExpiration {
    return entry.ObjectExpiration{
        .key = "foo",
        .expiration_ms = 1785000509089,
    };
}

pub fn clearExp(_: *anyopaque, _: []const u8) Storage.Error!void {
    return;
}
