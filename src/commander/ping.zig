const std = @import("std");
const resp = @import("../resp.zig");
const store = @import("../store.zig");
const Commander = @import("interface.zig");
const TestHelpers = @import("../tests/helpers.zig");
const DefaultStorage = @import("../storage/default_storage.zig");
const persistence = @import("../persistence.zig");

const Ping = @This();

allocator: std.mem.Allocator,
arguments: []resp.RESPValue,

pub fn commander(self: *Ping) Commander {
    return .{ .ptr = self, .vtable = &vtable };
}

const vtable = Commander.VTable{ .execute = execute, .deinit = deinit };

fn execute(_: *anyopaque, _: std.Io, _: *store.Store, _: *Commander.ClientState) Commander.Error!resp.RESPValue {
    return .{ .simple_string = "PONG" };
}

fn deinit(ptr: *anyopaque) void {
    const self: *Ping = @ptrCast(@alignCast(ptr));
    self.allocator.destroy(self);
}

test "execute ping command" {
    const testing = std.testing;
    var values = [_]resp.RESPValue{.{ .bulk_string = "PING" }};
    const command = try TestHelpers.initCommand(testing.allocator, .{ .array = &values });
    defer command.deinit();

    var default_storage = DefaultStorage.init(testing.io, testing.allocator);
    var kgc_backend = try persistence.KgcPersistence.init(testing.io, testing.allocator, "test.kgc");
    var memory_store = store.MemoryStore.init(&.{default_storage.storage()}, kgc_backend.snapshot());
    var data_store = memory_store.store();
    defer data_store.deinit();
    var client_state: Commander.ClientState = .{};

    const result = try command.execute(testing.io, &data_store, &client_state);
    switch (result) {
        .simple_string => |actual| try testing.expectEqualStrings("PONG", actual),
        else => return error.TestUnexpectedResult,
    }
}
