const std = @import("std");
const resp = @import("../resp.zig");
const store = @import("../store.zig");
const command_arguments = @import("arguments.zig");
const Commander = @import("interface.zig");
const TestHelpers = @import("../tests/helpers.zig");
const MockStore = @import("../store/mock_store.zig");
const Config = @import("../config.zig");

const Select = @This();

allocator: std.mem.Allocator,
arguments: []resp.RESPValue,

pub fn commander(self: *Select) Commander {
    return .{ .ptr = self, .vtable = &vtable };
}

const vtable = Commander.VTable{
    .execute = execute,
    .deinit = deinit,
};

fn execute(ptr: *anyopaque, _: std.Io, data_store: *store.Store, client_state: *Commander.ClientState) Commander.Error!Commander.Result {
    const self: *Select = @ptrCast(@alignCast(ptr));

    const index = try command_arguments.bulkStringInt(u32, self.arguments[0]);
    if (index >= data_store.numDatabases()) {
        return error.DbIndexOutOfRange;
    }

    client_state.db_index = index;
    return Commander.Result.borrowed(.{ .simple_string = "OK" });
}

fn deinit(ptr: *anyopaque) void {
    const self: *Select = @ptrCast(@alignCast(ptr));
    self.allocator.destroy(self);
}

test "execute selects a valid database" {
    const testing = std.testing;
    var values = [_]resp.RESPValue{
        .{ .bulk_string = "SELECT" },
        .{ .bulk_string = "1" },
    };
    const command = try TestHelpers.initCommand(testing.allocator, .{ .array = &values });
    defer command.deinit();

    var mock_store = MockStore.init();
    mock_store.num_databases_result = @intCast(Config.default().num_databases);
    var data_store = mock_store.store();
    var client_state: Commander.ClientState = .{};

    var result = try command.execute(testing.io, &data_store, &client_state);
    defer result.deinit();
    switch (result.value) {
        .simple_string => |actual| try testing.expectEqualStrings("OK", actual),
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(1, client_state.db_index);
}

test "rejects an out-of-range database index" {
    const testing = std.testing;
    var values = [_]resp.RESPValue{
        .{ .bulk_string = "SELECT" },
        .{ .bulk_string = "99" },
    };
    const command = try TestHelpers.initCommand(testing.allocator, .{ .array = &values });
    defer command.deinit();

    var mock_store = MockStore.init();
    mock_store.num_databases_result = @intCast(Config.default().num_databases);
    var data_store = mock_store.store();
    var client_state: Commander.ClientState = .{};

    try testing.expectError(error.DbIndexOutOfRange, command.execute(testing.io, &data_store, &client_state));
    try testing.expectEqual(0, client_state.db_index);
}
