const std = @import("std");
const Map = @import("map/Map.zig");

pub const Store = struct {
    _allocator: std.mem.Allocator,
    const Self = @This();

    pub fn deinit(_: *Self) void {}
};

pub fn init(allocator: std.mem.Allocator) Store {
    return Store{
        ._allocator = allocator,
    };
}
