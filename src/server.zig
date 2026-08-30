const std = @import("std");
const storage = @import("storage.zig");
const store = @import("store.zig");
const persistence = @import("persistence.zig");
const PersistenceState = @import("persistence_state.zig");
const ChangeTracker = @import("change_tracker.zig");
const Config = @import("config.zig");
const cron = @import("cron.zig");
const connection = @import("connection.zig");
const helpers = @import("helpers.zig");

const Server = @This();

_io: std.Io,
_allocator: std.mem.Allocator,
_config: Config,

_persistence_state: PersistenceState,
_change_tracker: ChangeTracker,
_kgc: persistence.KgcPersistence,
_aof: ?persistence.AofPersistence,

_default_storages: []storage.DefaultStorage,
_notifier_storages: []storage.NotifierStorage,
_data_storages: []storage.Interface,
_mem_store: store.MemoryStore,
_store: store.Store,

_listener: ?std.Io.net.Server = null,

/// Builds the whole object graph on the heap and returns a stable `*Server`.
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
    self._aof = null;

    self._default_storages = try allocator.alloc(storage.DefaultStorage, num_databases);
    errdefer allocator.free(self._default_storages);
    for (self._default_storages) |*s| s.* = storage.DefaultStorage.init(io, allocator);

    self._persistence_state = PersistenceState.init(io, config.exclusive_bg_persistence);

    self._kgc = try persistence.KgcPersistence.init(io, allocator, &self._persistence_state, config.snapshot_path);
    if (config.append_only) {
        self._aof = try persistence.AofPersistence.init(io, allocator, &self._persistence_state, config);
    }

    const kgc_snapshot = self._kgc.snapshot();
    const aof_journal: ?persistence.JournalPersistence = if (self._aof) |*aof| aof.journal() else null;

    // Load against the raw storages if aof is not enabled, before they're wrapped for AOF
    // notification below. This block and the wrapping below it must not be
    // reordered.
    // AOF is history and snapshot is a state, applying both would double-apply . So they are mutaully exclusive
    if (!config.append_only) {
        const raw_storages = try allocator.alloc(storage.Interface, num_databases);
        defer allocator.free(raw_storages);
        for (0..num_databases) |i| raw_storages[i] = self._default_storages[i].storage();
        try kgc_snapshot.load(raw_storages);
    }

    self._change_tracker = ChangeTracker.init(io);

    self._notifier_storages = try allocator.alloc(storage.NotifierStorage, num_databases);
    errdefer allocator.free(self._notifier_storages);

    self._data_storages = try allocator.alloc(storage.Interface, num_databases);
    errdefer allocator.free(self._data_storages);

    for (0..num_databases) |i| {
        self._notifier_storages[i] = storage.NotifierStorage.init(
            allocator,
            self._default_storages[i].storage(),
            aof_journal,
            &self._change_tracker,
            @intCast(i),
        );
        self._data_storages[i] = self._notifier_storages[i].storage();
    }

    self._mem_store = store.MemoryStore.init(
        self._data_storages,
        kgc_snapshot,
        aof_journal,
        &self._change_tracker,
    );
    self._store = self._mem_store.store();

    // TODO: if aof is enabled, replay aof through the store
    return self;
}

/// Unwinds `create` in reverse. `_store.deinit()` chains through
/// `MemoryStore.deinit` -> `NotifierStorage.deinit` -> `DefaultStorage.deinit`,
/// so the storage backends must not be deinitialized separately here.
pub fn destroy(self: *Server) void {
    // flush out buffered datas and clear it before tearning down store
    if (self._aof) |*aof| {
        aof.journal().deinit() catch |err| {
            helpers.logStderr(self._io, "server: failed to destoy: {s}\n", .{@errorName(err)});
        };
    }

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

    const aof_journal: ?persistence.JournalPersistence = if (self._aof) |*aof| aof.journal() else null;
    const cron_thread = try std.Thread.spawn(.{}, cron.run, .{
        self._io,
        self._allocator,
        self._data_storages,
        &self._persistence_state,
        &self._change_tracker,
        &self._store,
        aof_journal,
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

fn writeKgcSnapshotWithFooBar(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
    var backend = storage.DefaultStorage.init(io, allocator);
    var backend_storage = backend.storage();
    defer backend_storage.deinit();

    {
        var tx = try backend_storage.begin();
        defer tx.end();
        _ = try backend_storage.put("foo", .{ .string = "bar" }, .{ .expires_at = null });
    }

    var persistence_state = PersistenceState.init(io, false);
    var kgc_backend = try persistence.KgcPersistence.init(io, allocator, &persistence_state, path);
    try kgc_backend.snapshot().save(&.{backend_storage});
}

test "create with appendonly off builds no aof backend and creates no append directory" {
    const testing = std.testing;
    const cwd = std.Io.Dir.cwd();
    const dirname = "scratch-server-appendonly-off-no-dir";

    cwd.deleteTree(testing.io, dirname) catch {};
    defer cwd.deleteTree(testing.io, dirname) catch {};

    var config = Config.default();
    config.append_dirname = dirname;

    const server = try Server.create(testing.io, testing.allocator, config);
    try testing.expect(server._aof == null);
    server.destroy();

    try testing.expectError(error.FileNotFound, cwd.openDir(testing.io, dirname, .{}));
}

test "create with appendonly on opens the append directory and destroy leaves no leaks" {
    const testing = std.testing;
    const cwd = std.Io.Dir.cwd();
    const dirname = "scratch-server-appendonly-on-opens-dir";

    cwd.deleteTree(testing.io, dirname) catch {};
    defer cwd.deleteTree(testing.io, dirname) catch {};

    var config = Config.default();
    config.append_only = true;
    config.append_dirname = dirname;

    const server = try Server.create(testing.io, testing.allocator, config);
    try testing.expect(server._aof != null);

    var dir = try cwd.openDir(testing.io, dirname, .{});
    dir.close(testing.io);

    server.destroy();
}

test "create with appendonly on does not load the kgc snapshot" {
    const testing = std.testing;
    const cwd = std.Io.Dir.cwd();
    const dirname = "scratch-server-appendonly-on-skips-kgc";
    const snapshot_path = "scratch-server-appendonly-on-skips-kgc.kgc";

    cwd.deleteTree(testing.io, dirname) catch {};
    defer cwd.deleteTree(testing.io, dirname) catch {};
    defer cwd.deleteFile(testing.io, snapshot_path) catch {};

    try writeKgcSnapshotWithFooBar(testing.io, testing.allocator, snapshot_path);

    var config = Config.default();
    config.append_only = true;
    config.append_dirname = dirname;
    config.snapshot_path = snapshot_path;

    const server = try Server.create(testing.io, testing.allocator, config);
    defer server.destroy();

    const loaded = try server._store.get("foo", 0);
    try testing.expect(loaded == null);
}

test "create with appendonly off still loads the kgc snapshot" {
    const testing = std.testing;
    const cwd = std.Io.Dir.cwd();
    const snapshot_path = "scratch-server-appendonly-off-loads-kgc.kgc";

    defer cwd.deleteFile(testing.io, snapshot_path) catch {};

    try writeKgcSnapshotWithFooBar(testing.io, testing.allocator, snapshot_path);

    var config = Config.default();
    config.snapshot_path = snapshot_path;

    const server = try Server.create(testing.io, testing.allocator, config);
    defer server.destroy();

    const loaded = try server._store.get("foo", 0) orelse return error.TestUnexpectedResult;
    switch (loaded) {
        .string => |str| try testing.expectEqualStrings("bar", str),
    }
}
