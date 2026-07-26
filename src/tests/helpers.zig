// TODO: Refactor: This file could become a dumping ground
// research what is the idiomatic Zig way of doing this type of stuff
const std = @import("std");
const commander = @import("../commander.zig");
const resp = @import("../resp.zig");
const store = @import("../store.zig");
const DefaultStorage = @import("../storage/default_storage.zig");

pub fn executeWithMemoryStore(command: commander.Commander) commander.Error!resp.RESPValue {
    const testing = std.testing;
    defer command.deinit();

    var default_storage = DefaultStorage.init(testing.allocator);
    var memory_store = store.MemoryStore.init(default_storage.storage());
    var data_store = memory_store.store();
    defer data_store.deinit();

    return command.execute(testing.io, &data_store);
}

pub fn initCommand(allocator: std.mem.Allocator, value: resp.RESPValue) commander.Error!commander.Commander {
    return commander.init(allocator, value);
}
