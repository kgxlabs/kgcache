// TODO: Refactor: This file could become a dumping ground
// research what is the idiomatic Zig way of doing this type of stuff
const std = @import("std");
const commander = @import("../commander.zig");
const resp = @import("../resp.zig");
const store = @import("../store.zig");
const ClientState = @import("../client_state.zig");
const DefaultStorage = @import("../storage/default_storage.zig");
const persistence = @import("../persistence.zig");
const PersistenceState = @import("../persistence_state.zig");
const ChangeTracker = @import("../change_tracker.zig");

pub fn executeWithMemoryStore(command: commander.Commander) commander.Error!resp.RESPValue {
    const testing = std.testing;
    defer command.deinit();

    var default_storage = DefaultStorage.init(testing.io, testing.allocator);
    // `catch unreachable`: the path is a literal known to end in `.kgc`, so
    // `InitError.InvalidExtension` can't actually happen here -- and this
    // function's return type is `commander.Error`, which that error isn't
    // part of.
    var persistence_state = PersistenceState.init(testing.io, false);
    var kgc_backend = persistence.KgcPersistence.init(testing.io, testing.allocator, &persistence_state, "test.kgc") catch unreachable;
    var change_tracker = ChangeTracker.init(testing.io);
    var memory_store = store.MemoryStore.init(&.{default_storage.storage()}, kgc_backend.snapshot(), &change_tracker);
    var data_store = memory_store.store();
    defer data_store.deinit();
    var client_state: ClientState = .{};

    return command.execute(testing.io, &data_store, &client_state);
}

pub fn initCommand(allocator: std.mem.Allocator, value: resp.RESPValue) commander.Error!commander.Commander {
    return commander.init(allocator, value);
}
