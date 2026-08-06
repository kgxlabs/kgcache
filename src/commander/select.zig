const std = @import("std");
const resp = @import("../resp.zig");
const store = @import("../store.zig");
const command_arguments = @import("arguments.zig");
const Commander = @import("interface.zig");
const TestHelpers = @import("../tests/helpers.zig");
const MockStore = @import("../store/mock_store.zig");

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

fn execute(ptr: *anyopaque, _: std.Io, data_store: *store.Store, client_state: *Commander.ClientState) Commander.Error!resp.RESPValue {
    const self: *Select = @ptrCast(@alignCast(ptr));

    if (self.arguments.len != 1) {
        return .{ .simple_error = "Wrong number of arguments" };
    }

    const index = try command_arguments.bulkStringInt(u32, self.arguments[0]);
    if (index >= data_store.numDatabases()) {
        return .{ .simple_error = "ERR DB index is out of range" };
    }

    client_state.db_index = index;
    return .{ .simple_string = "OK" };
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
    mock_store.num_databases_result = 16;
    var data_store = mock_store.store();
    var client_state: Commander.ClientState = .{};

    const result = try command.execute(testing.io, &data_store, &client_state);
    switch (result) {
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
    mock_store.num_databases_result = 16;
    var data_store = mock_store.store();
    var client_state: Commander.ClientState = .{};

    const result = try command.execute(testing.io, &data_store, &client_state);
    switch (result) {
        .simple_error => |message| try testing.expectEqualStrings("ERR DB index is out of range", message),
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(0, client_state.db_index);
}

test "rejects wrong number of arguments" {
    const testing = std.testing;
    var values = [_]resp.RESPValue{.{ .bulk_string = "SELECT" }};
    const command = try TestHelpers.initCommand(testing.allocator, .{ .array = &values });

    const result = try TestHelpers.executeWithMemoryStore(command);
    switch (result) {
        .simple_error => |message| try testing.expectEqualStrings("Wrong number of arguments", message),
        else => return error.TestUnexpectedResult,
    }
}
