const std = @import("std");
const Store = @import("store.zig");
const object = @import("../object.zig");
const entry = @import("../entry.zig");

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

pub fn deinit(_: *anyopaque) void {
    // const self: *MemoryStore = @ptrCast(@alignCast(ptr));
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
fn set(_: *anyopaque, key: []const u8, value: []const u8) Store.Error!?object.Object {
    // const self: *MemoryStore = @ptrCast(@alignCast(ptr));

    std.debug.print("{s}: {s}\n", .{ key, value });
    return null;
}
