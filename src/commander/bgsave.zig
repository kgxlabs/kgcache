const std = @import("std");
const resp = @import("../resp.zig");
const store = @import("../store.zig");
const Commander = @import("interface.zig");
const TestHelpers = @import("../tests/helpers.zig");
const DefaultStorage = @import("../storage/default_storage.zig");
const persistence = @import("../persistence.zig");

const BgSave = @This();

allocator: std.mem.Allocator,
arguments: []resp.RESPValue,

pub fn commander(self: *BgSave) Commander {
    return .{ .ptr = self, .vtable = &vtable };
}

const vtable = Commander.VTable{ .execute = execute, .deinit = deinit };

fn execute(_: *anyopaque, _: std.Io, _: *store.Store, _: *Commander.ClientState) Commander.Error!resp.RESPValue {
    return .{ .simple_string = "OK" };
}

fn deinit(ptr: *anyopaque) void {
    const self: *BgSave = @ptrCast(@alignCast(ptr));
    self.allocator.destroy(self);
}
