const std = @import("std");
const Store = @import("store.zig");
const object = @import("../object.zig");
const entry = @import("../entry.zig");
const testing = std.testing;

const MemoryStore = @This();

const ValueMap = std.StringHashMap(entry.ObjectEntry);
const ExpirationMap = std.StringHashMap(entry.ObjectExpirationMs);

_allocator: std.mem.Allocator,
_map: ValueMap,
_exp_map: ExpirationMap,

pub fn init(allocator: std.mem.Allocator) MemoryStore {
    return .{
        ._allocator = allocator,
        ._map = ValueMap.init(allocator),
        ._exp_map = ExpirationMap.init(allocator),
    };
}

pub fn deinit(ptr: *anyopaque) void {
    const self: *MemoryStore = @ptrCast(@alignCast(ptr));
    var iterator = self._map.iterator();
    while (iterator.next()) |item| {
        self._allocator.free(item.key_ptr.*);

        switch (item.value_ptr.value) {
            .string => |value| self._allocator.free(value),
        }
    }

    self._map.deinit();
    self._exp_map.deinit();
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
    .deinit = deinit,
};

fn get(ptr: *anyopaque, key: []const u8) Store.Error!?object.Object {
    const self: *MemoryStore = @ptrCast(@alignCast(ptr));
    const value = self._map.get(key) orelse return null;
    return value.value;
}

// TODO: Support all of these options
// SET key value [NX | XX | IFEQ ifeq-value | IFNE ifne-value |
// IFDEQ ifdeq-digest | IFDNE ifdne-digest] [GET] [EX seconds |
// PX milliseconds | EXAT unix-time-seconds |
// PXAT unix-time-milliseconds | KEEPTTL]
fn set(ptr: *anyopaque, key: []const u8, value: []const u8) Store.Error!?object.Object {
    const self: *MemoryStore = @ptrCast(@alignCast(ptr));
    // TODO: Accept options params and process them
    if (self._map.getPtr(key)) |existing| {
        const owned_value = try self._allocator.dupe(u8, value);

        const old_value = existing.value;
        // TODO: Handle all types
        existing.value = .{ .string = owned_value };

        self._allocator.free(old_value.string);
        return null;
    }

    const owned_key = try self._allocator.dupe(u8, key);
    errdefer self._allocator.free(owned_key);

    const owned_value = try self._allocator.dupe(u8, value);
    errdefer self._allocator.free(owned_value);

    self._map.put(owned_key, .{
        .value = .{
            .string = owned_value,
        },
    }) catch return Store.Error.OutOfMemory;

    return null;
}

test "set stores a value and returns null" {
    var memory_store = testMemoryStore();
    var data_store = memory_store.store();

    defer data_store.deinit();

    const key = "foo";
    const value = "barz";

    const set_value = try data_store.set(key, value);

    try testing.expect(set_value == null);

    const get_value = try data_store.get(key) orelse return error.TestUnexpectedResult;
    try expectObjectString(get_value, value);
}

test "get returns null for a missing key" {
    var memory_store = testMemoryStore();
    var data_store = memory_store.store();
    defer data_store.deinit();

    const value = try data_store.get("missing");

    try testing.expect(value == null);
}

test "set replaces an existing value" {
    var memory_store = testMemoryStore();
    var data_store = memory_store.store();
    defer data_store.deinit();

    _ = try data_store.set("key", "first");
    const result = try data_store.set("key", "second");

    try testing.expect(result == null);

    const value = try data_store.get("key") orelse return error.TestUnexpectedResult;
    try expectObjectString(value, "second");
}

test "set owns the key and value bytes" {
    var memory_store = testMemoryStore();
    var data_store = memory_store.store();
    defer data_store.deinit();

    var key = [_]u8{ 'k', 'e', 'y' };
    var value = [_]u8{ 'o', 'n', 'e' };
    _ = try data_store.set(&key, &value);

    @memset(&key, 'x');
    @memset(&value, 'x');

    const stored_value = try data_store.get("key") orelse return error.TestUnexpectedResult;
    try expectObjectString(stored_value, "one");
}

fn expectObjectString(value: object.Object, expected: []const u8) !void {
    switch (value) {
        .string => |str| {
            try testing.expectEqualStrings(expected, str);
        },
    }
}

fn testMemoryStore() MemoryStore {
    return MemoryStore.init(testing.allocator);
}
