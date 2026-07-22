// TODO: Refactor: This file could become a dumping ground
// research what is the idiomatic Zig way of doing this type of stuff

const std = @import("std");
const commander = @import("../commander.zig");
const resp = @import("../resp.zig");
const store = @import("../store.zig");

pub fn executeWithMemoryStore(command: commander.Commander) commander.Error!resp.RESPValue {
    const testing = std.testing;
    defer command.deinit();

    var memory_store = store.MemoryStore.init(testing.allocator);
    var data_store = memory_store.store();
    defer data_store.deinit();

    return command.execute(&data_store);
}
