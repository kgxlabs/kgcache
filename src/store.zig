const std = @import("std");
const Map = @import("map/Map.zig");
const object = @import("object.zig");

pub const Store = struct {
    _allocator: std.mem.Allocator,
    const Self = @This();

    pub fn get(_: *Self, _: []const u8) !object.Object {
        return object.Object{ .string = "" };
    }

    pub fn deinit(_: *Self) void {}
};

pub fn init(allocator: std.mem.Allocator) Store {
    return Store{
        ._allocator = allocator,
    };
}
