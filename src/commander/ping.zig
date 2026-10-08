const std = @import("std");
const store = @import("../store.zig");
const Commander = @import("interface.zig");
const TestHelpers = @import("../tests/helpers.zig");
const DefaultStorage = @import("../storage/default_storage.zig");
const persistence = @import("../persistence.zig");
const PersistenceState = @import("../persistence_state.zig");

const Ping = @This();

allocator: std.mem.Allocator,
arguments: []const []const u8,

pub fn commander(self: *Ping) Commander {
    return .{ .ptr = self, .vtable = &vtable };
}

const vtable = Commander.VTable{ .execute = execute, .deinit = deinit };

fn execute(ptr: *anyopaque, _: std.Io, _: *store.Store, _: *Commander.ClientState) Commander.Error!Commander.Result {
    const self: *Ping = @ptrCast(@alignCast(ptr));
    if (self.arguments.len == 0) return Commander.Result.borrowed(.{ .simple_string = "PONG" });

    const message = self.arguments[0];
    return Commander.Result.borrowed(.{ .blob_string = message });
}

fn deinit(ptr: *anyopaque) void {
    const self: *Ping = @ptrCast(@alignCast(ptr));
    self.allocator.destroy(self);
}

test "execute ping command" {
    const testing = std.testing;
    const values = [_][]const u8{"PING"};
    const command = try TestHelpers.initCommand(testing.allocator, .{ .name = values[0], .arguments = values[1..] });
    defer command.deinit();

    var default_storage = DefaultStorage.init(testing.io, testing.allocator);
    var persistence_state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });
    var kgc_backend = try persistence.KgcPersistence.init(testing.io, testing.allocator, &persistence_state, "test.kgc");
    var memory_store = store.MemoryStore.init(
        testing.allocator,
        &.{default_storage.storage()},
        kgc_backend.snapshot(),
        null,
    );
    var data_store = memory_store.store();
    defer data_store.deinit();
    var client_state: Commander.ClientState = .{};

    var result = try command.execute(testing.io, &data_store, &client_state);
    defer result.deinit();
    switch (result.value) {
        .simple_string => |actual| try testing.expectEqualStrings("PONG", actual),
        else => return error.TestUnexpectedResult,
    }
}
