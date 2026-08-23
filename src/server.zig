const std = @import("std");
const storage = @import("storage.zig");
const store = @import("store.zig");
const persistence = @import("persistence.zig");
const PersistenceState = @import("persistence_state.zig");
const Config = @import("config.zig");
const cron = @import("cron.zig");
const connection = @import("connection.zig");

const Server = @This();

_io: std.Io,
_allocator: std.mem.Allocator,
_config: Config,

_persistence_state: PersistenceState,
_kgc: persistence.KgcPersistence,
_aof: persistence.AofPersistence,

_default_storages: []storage.DefaultStorage,
_notifier_storages: []storage.NotifierStorage,
_data_storages: []storage.Interface,
_mem_store: store.MemoryStore,
_store: store.Store,

_listener: ?std.Io.net.Server = null,

/// Builds the whole object graph on the heap and returns a stable `*Server`.
///
/// This must return `*Server`, never `Server` by value: `_kgc`, `_aof`, and
/// `_mem_store` (via `_kgc`/`_data_storages`) capture pointers back into
/// `self`'s own fields. Returning `Server` by value would copy those fields
/// to a new address while the captured pointers kept pointing at this
/// function's now-dead stack frame => silent memory corruption, not a
/// compile error. Heap allocation gives `self` a permanent address before
/// any self-referential field is built.
pub fn create(io: std.Io, allocator: std.mem.Allocator, config: Config) !*Server {
    const self = try allocator.create(Server);
    errdefer allocator.destroy(self);

    const num_databases = config.num_databases;

    self._io = io;
    self._allocator = allocator;
    self._config = config;
    self._listener = null;

    self._default_storages = try allocator.alloc(storage.DefaultStorage, num_databases);
    errdefer allocator.free(self._default_storages);
    for (self._default_storages) |*s| s.* = storage.DefaultStorage.init(io, allocator);

    self._persistence_state = PersistenceState.init(io, config.exclusive_bg_persistence);

    self._kgc = try persistence.KgcPersistence.init(io, allocator, &self._persistence_state, config.snapshot_path);
    self._aof = persistence.AofPersistence.init(allocator, &self._persistence_state);

    const kgc_snapshot = self._kgc.snapshot();
    const aof_journal = self._aof.journal();

    // Load against the raw storages, before they're wrapped for AOF
    // notification below. This block and the wrapping below it must not be
    // reordered.
    {
        const raw_storages = try allocator.alloc(storage.Interface, num_databases);
        defer allocator.free(raw_storages);
        for (0..num_databases) |i| raw_storages[i] = self._default_storages[i].storage();
        try kgc_snapshot.load(raw_storages);
    }

    self._notifier_storages = try allocator.alloc(storage.NotifierStorage, num_databases);
    errdefer allocator.free(self._notifier_storages);

    self._data_storages = try allocator.alloc(storage.Interface, num_databases);
    errdefer allocator.free(self._data_storages);

    for (0..num_databases) |i| {
        self._notifier_storages[i] = storage.NotifierStorage.init(
            allocator,
            self._default_storages[i].storage(),
            aof_journal,
            @intCast(i),
        );
        self._data_storages[i] = self._notifier_storages[i].storage();
    }

    self._mem_store = store.MemoryStore.init(self._data_storages, kgc_snapshot);
    self._store = self._mem_store.store();

    return self;
}

/// Unwinds `create` in reverse. `_store.deinit()` chains through
/// `MemoryStore.deinit` -> `NotifierStorage.deinit` -> `DefaultStorage.deinit`,
/// so the storage backends must not be deinitialized separately here.
pub fn destroy(self: *Server) void {
    self._store.deinit();

    self._allocator.free(self._data_storages);
    self._allocator.free(self._notifier_storages);
    self._allocator.free(self._default_storages);

    self._allocator.destroy(self);
}

/// The listener is bound here rather than in `create` so `create` can be
/// exercised in tests without touching the network.
pub fn run(self: *Server) !void {
    const address = try std.Io.net.IpAddress.parseIp4(self._config.bind_address, self._config.port);

    self._listener = try address.listen(self._io, .{
        .reuse_address = self._config.reuse_address,
    });
    defer self._listener.?.deinit(self._io);

    const cron_thread = try std.Thread.spawn(.{}, cron.run, .{
        self._io,
        self._allocator,
        self._data_storages,
        &self._persistence_state,
        self._config,
    });
    cron_thread.detach();

    try connection.acceptLoop(self._io, &self._listener.?, &self._store, self._allocator, self._config);
}

test "create builds the full object graph and destroy leaks nothing" {
    const testing = std.testing;

    const server = try Server.create(testing.io, testing.allocator, Config.default());
    server.destroy();
}
