const std = @import("std");
const Map = @import("map/Map.zig");
const object = @import("object.zig");

pub const StoreError = error{};

pub const Store = struct {
    _allocator: std.mem.Allocator,
    const Self = @This();

    pub fn get(_: *Self, _: []const u8) StoreError!?object.Object {
        return object.Object{ .string = "" };
    }

    // TODO: Support all of these options
    // SET key value [NX | XX | IFEQ ifeq-value | IFNE ifne-value |
    // IFDEQ ifdeq-digest | IFDNE ifdne-digest] [GET] [EX seconds |
    // PX milliseconds | EXAT unix-time-seconds |
    // PXAT unix-time-milliseconds | KEEPTTL]
    pub fn set(_: *Self, key: []const u8, value: []const u8) StoreError!?object.Object {
        std.debug.print("{s}: {s}\n", .{ key, value });
        return null;
    }

    pub fn deinit(_: *Self) void {}
};

pub fn init(allocator: std.mem.Allocator) Store {
    return Store{
        ._allocator = allocator,
    };
}

pub fn errorToString(err: StoreError) []const u8 {
    return switch (err) {
        else => "Something went wrong",
    };
}
