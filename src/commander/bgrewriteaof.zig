const std = @import("std");
const resp = @import("../resp.zig");
const store = @import("../store.zig");
const Commander = @import("interface.zig");

const BgRewriteAof = @This();

allocator: std.mem.Allocator,
arguments: []resp.RESPValue,

pub fn commander(self: *BgRewriteAof) Commander {
    return .{ .ptr = self, .vtable = &vtable };
}

const vtable = Commander.VTable{
    .execute = execute,
    .deinit = deinit,
};

fn execute(_: *anyopaque, _: std.Io, data_store: *store.Store, _: *Commander.ClientState) anyerror!Commander.Result {
    const outcome = try data_store.bgrewriteaof(.manual);
    return Commander.Result.borrowed(.{ .simple_string = switch (outcome) {
        .started => "Background append only file rewriting started",
        .scheduled => "Background append only file rewriting scheduled",
    } });
}

fn deinit(ptr: *anyopaque) void {
    const self: *BgRewriteAof = @ptrCast(@alignCast(ptr));
    self.allocator.destroy(self);
}
