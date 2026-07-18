const std = @import("std");
const Store = @import("store.zig");
const object = @import("../object.zig");
const entry = @import("../entry.zig");
const testing = std.testing;

const MemoryStore = @This();

const ValueMap = std.StringHashMap(entry.ObjectEntry);
const ExpirationMap = std.StringHashMap(entry.ObjectExpirationMs);

_map: ValueMap,
_exp_map: ExpirationMap,

pub fn init(allocator: std.mem.Allocator) MemoryStore {
    return .{
        ._map = ValueMap.init(allocator),
        ._exp_map = ExpirationMap.init(allocator),
    };
}

pub fn deinit(ptr: *anyopaque) void {
    const self: *MemoryStore = @ptrCast(@alignCast(ptr));
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

fn get(_: *anyopaque, _: []const u8) Store.Error!?object.Object {
    // const self: *MemoryStore = @ptrCast(@alignCast(ptr));
    return object.Object{ .string = "" };
}

// TODO: Support all of these options
// SET key value [NX | XX | IFEQ ifeq-value | IFNE ifne-value |
// IFDEQ ifdeq-digest | IFDNE ifdne-digest] [GET] [EX seconds |
// PX milliseconds | EXAT unix-time-seconds |
// PXAT unix-time-milliseconds | KEEPTTL]
fn set(ptr: *anyopaque, key: []const u8, value: []const u8) Store.Error!?object.Object {
    const self: *MemoryStore = @ptrCast(@alignCast(ptr));
    std.debug.print("{s}: {s}\n", .{ key, value });
    const obj_entry: entry.ObjectEntry = .{ .value = .{
        .string = value,
    } };

    self._map.put(key, obj_entry) catch return Store.Error.OutOfMemory;

    // TODO: Accept options params and process them
    return null;
}

test "set value with no options should return null" {
    const map = ValueMap.init(testing.allocator);
    const exp_map = ExpirationMap.init(testing.allocator);
    const data_store = Store{
        ._map = map,
        ._exp_map = exp_map,
    };

    defer data_store.deinit();

    const key = "foo";
    const value = "barz";
    const object_entry: entry.ObjectEntry = .{ .value = .{ .string = value } };

    const set_value = try data_store.set(key, object_entry);

    try testing.expect(set_value == null);

    const get_value = map.get(key);
    try testing.expect(get_value != null);
    try expectObjectString(get_value, value);
}

fn expectObjectString(value: object.Object, expected: []const u8) !void {
    switch (value) {
        .string => |str| {
            try testing.expectEqualStrings(expected, str);
        },
        else => return error.TestUnexpectedResult,
    }
}

fn testDataStore(allocator: std.mem.Allocator) Store {
    return Store{
        ._map = ValueMap.init(allocator),
        ._exp_map = ExpirationMap.init(allocator),
    };
}
