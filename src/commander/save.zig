const std = @import("std");
const resp = @import("../resp.zig");
const store = @import("../store.zig");
const Commander = @import("interface.zig");
const TestHelpers = @import("../tests/helpers.zig");
const DefaultStorage = @import("../storage/default_storage.zig");
const persistence = @import("../persistence.zig");
const time = @import("../time.zig");

const Save = @This();

allocator: std.mem.Allocator,
arguments: []resp.RESPValue,

pub fn commander(self: *Save) Commander {
    return .{ .ptr = self, .vtable = &vtable };
}

const vtable = Commander.VTable{ .execute = execute, .deinit = deinit };

fn execute(_: *anyopaque, _: std.Io, data_store: *store.Store, _: *Commander.ClientState) anyerror!resp.RESPValue {
    try data_store.save();
    return resp.RESPValue{ .simple_string = "OK" };
}

fn deinit(ptr: *anyopaque) void {
    const self: *Save = @ptrCast(@alignCast(ptr));
    self.allocator.destroy(self);
}
