const std = @import("std");
const storage = @import("storage.zig");
const store = @import("store.zig");
const persistence = @import("persistence.zig");
const PersistenceState = @import("persistence_state.zig");
const Manifest = @import("persistence/manifest.zig");
const Config = @import("config.zig");
const cron = @import("cron.zig");
const ConnectionManager = @import("connection_manager.zig");
const time = @import("time.zig");
const logging = @import("logger.zig");

const Server = @This();

_io: std.Io,
_allocator: std.mem.Allocator,
_config: Config,
// Borrowed from the caller. Server does not own or release the logger implementation.
_logger: logging.Logger,

_persistence_state: PersistenceState,
_kgc: persistence.KgcPersistence,
_aof: ?persistence.AofPersistence,

_default_storages: []storage.DefaultStorage,
_notifier_storages: []storage.NotifierStorage,
_data_storages: []storage.Interface,
_mem_store: store.MemoryStore,
_store: store.Store,
_connection_manager: ConnectionManager,

_listener: ?std.Io.net.Server = null,
_cron_stop_requested: std.atomic.Value(bool) = .init(false),
_cron_thread: ?std.Thread = null,

/// Builds the whole object graph on the heap and returns a stable `*Server`.
/// This must return `*Server`, never `Server` by value: `_kgc`, `_aof`,
/// `_mem_store` (via `_kgc`/`_data_storages`), and `_connection_manager`
/// capture pointers back into `self`'s own fields. Returning `Server` by value
/// would copy those fields to a new address while the captured pointers kept
/// pointing at this function's now-dead stack frame, causing silent memory
/// corruption. Heap allocation gives `self` a permanent address before any
/// self-referential field is built.
pub fn create(io: std.Io, allocator: std.mem.Allocator, config: Config, logger: logging.Logger) !*Server {
    const self = try allocator.create(Server);
    errdefer allocator.destroy(self);

    const num_databases = config.num_databases;

    self._io = io;
    self._allocator = allocator;
    self._config = config;
    self._logger = logger;
    self._listener = null;
    self._cron_stop_requested = .init(false);
    self._cron_thread = null;
    self._aof = null;

    self._default_storages = try allocator.alloc(storage.DefaultStorage, num_databases);
    for (self._default_storages) |*s| s.* = storage.DefaultStorage.init(io, allocator);
    errdefer {
        for (self._default_storages) |*s| s.storage().deinit();
        allocator.free(self._default_storages);
    }

    self._persistence_state = PersistenceState.init(io, .{ .mutual_exclusive = config.exclusive_bg_persistence });

    self._kgc = try persistence.KgcPersistence.init(io, allocator, &self._persistence_state, config.snapshot_path);
    self._kgc._logger = logger;
    if (config.append_only) {
        self._aof = try persistence.AofPersistence.init(io, allocator, &self._persistence_state, config);
        self._aof.?._logger = logger;
    }
    errdefer if (self._aof) |*aof| aof.journal().deinit() catch |err| {
        logger.err("server: failed to close AOF after startup failure", err, @errorReturnTrace());
    };

    const kgc_snapshot = self._kgc.snapshot();
    const maybe_aof_journal: ?persistence.JournalPersistence = if (self._aof) |*aof| aof.journal() else null;

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

    self._notifier_storages = try allocator.alloc(storage.NotifierStorage, num_databases);
    errdefer allocator.free(self._notifier_storages);

    self._data_storages = try allocator.alloc(storage.Interface, num_databases);
    errdefer allocator.free(self._data_storages);

    for (0..num_databases) |i| {
        self._notifier_storages[i] = storage.NotifierStorage.init(
            io,
            allocator,
            self._default_storages[i].storage(),
            maybe_aof_journal,
            &self._persistence_state,
            @intCast(i),
        );
        self._data_storages[i] = self._notifier_storages[i].storage();
    }

    self._mem_store = store.MemoryStore.init(
        allocator,
        self._data_storages,
        kgc_snapshot,
        maybe_aof_journal,
    );
    self._store = self._mem_store.store();
    self._connection_manager = ConnectionManager.init(
        io,
        allocator,
        logger,
        &self._store,
        config.connection_buffer_size,
    );
    errdefer self._connection_manager.deinit() catch |err| {
        logger.err("server: failed to deinitialize connection manager after startup failure", err, @errorReturnTrace());
    };

    // start aof replay
    if (config.append_only) {
        try loadAof(self, io, allocator);
        // clean up files related to interrupted rewrite from previous rewrite run
        // this needs to be after successfully loading aof. couple of leftovers files from previous failed rewrite costs basically nothing
        try cleanupFailedAof(self, io, allocator, config);
    }

    return self;
}

/// The listener is bound here rather than in `create` so `create` can be
/// exercised in tests without touching the network.
pub fn run(self: *Server) !void {
    const address = try std.Io.net.IpAddress.parseIp4(self._config.bind_address, self._config.port);

    self._listener = try address.listen(self._io, .{
        .reuse_address = self._config.reuse_address,
    });
    defer self._listener.?.deinit(self._io);

    try self.startCron();
    defer self.stopCron();

    var log_buffer: [96]u8 = undefined;
    const started_message = std.fmt.bufPrint(
        &log_buffer,
        "server: started and listening on {s}:{d}",
        .{ self._config.bind_address, self._config.port },
    ) catch "server: started and listening";
    self._logger.info(started_message);

    while (true) {
        const client_stream = try self._listener.?.accept(self._io);
        try self._connection_manager.start(client_stream);
        try self._connection_manager.reapFinished();
    }
}

/// Unwinds `create` in reverse. `_store.deinit()` chains through
/// `MemoryStore.deinit` -> `NotifierStorage.deinit` -> `DefaultStorage.deinit`,
/// so the storage backends must not be deinitialized separately here.
/// Returns the first cleanup source after freeing the rest of the server.
pub fn destroy(self: *Server) anyerror!void {
    self.stopCron();

    var cleanup_error: ?anyerror = null;
    self._connection_manager.deinit() catch |err| {
        cleanup_error = err;
    };

    if (self._aof) |*aof| {
        aof.journal().deinit() catch |err| {
            if (cleanup_error == null) cleanup_error = err;
        };
    }

    self._store.deinit();

    self._allocator.free(self._data_storages);
    self._allocator.free(self._notifier_storages);
    self._allocator.free(self._default_storages);
    self._allocator.destroy(self);

    if (cleanup_error) |err| return err;
}

fn loadAof(self: *Server, io: std.Io, allocator: std.mem.Allocator) !void {
    const aof = if (self._aof) |*backend| backend else unreachable;

    const journal = aof.journal();
    journal.beginLoading();
    defer journal.endLoading();

    const stats = try persistence.AofLoader.replay(io, allocator, &self._store, self._config);

    aof.finishLoading(stats.base_size, stats.incr_bytes, stats.file_offset);

    // Replay uses the normal storage path, which increments the dirty count.
    // These changes are already stored in the AOF, so startup begins clean.
    var state_tx = self._persistence_state.beginUncancelable();
    defer state_tx.end();
    try self._persistence_state.markSaved(
        self._persistence_state.captureSnapshotChangeCount(),
        time.nowMs(io),
    );
}

fn cleanupFailedAof(self: *Server, io: std.Io, allocator: std.mem.Allocator, config: Config) !void {
    const aof = if (self._aof) |*backend| backend else unreachable;
    const journal = aof.journal();

    const cwd = std.Io.Dir.cwd();
    // open in iterate mode
    var dir = try cwd.openDir(io, config.append_dirname, .{ .iterate = true });
    defer dir.close(io);

    const manifest_name = try Manifest.manifestName(allocator, config.append_filename);
    defer allocator.free(manifest_name);

    const manifest = try Manifest.read(io, allocator, dir, manifest_name);
    defer if (manifest) |live_manifest| live_manifest.deinit(allocator);

    try journal.reconcile(io, allocator, dir, config.append_filename, manifest);
}

fn startCron(self: *Server) !void {
    std.debug.assert(self._cron_thread == null);
    self._cron_stop_requested.store(false, .release);

    const aof_journal: ?persistence.JournalPersistence = if (self._aof) |*aof| aof.journal() else null;
    self._cron_thread = try std.Thread.spawn(.{}, cron.run, .{
        self._io,
        self._logger,
        self._allocator,
        self._data_storages,
        &self._persistence_state,
        &self._store,
        aof_journal,
        self._config,
        &self._cron_stop_requested,
    });
}

fn stopCron(self: *Server) void {
    const thread = self._cron_thread orelse return;
    self._cron_stop_requested.store(true, .release);
    thread.join();
    self._cron_thread = null;
}

test "server owns and joins the cron thread" {
    const testing = std.testing;
    var config = Config.default();
    config.cron_interval_ms = 1;

    const server = try Server.create(testing.io, testing.allocator, config, logging.NoopLogger.logger());
    defer server.destroy() catch unreachable;

    try server.startCron();
    try testing.expect(server._cron_thread != null);

    server.stopCron();
    try testing.expect(server._cron_thread == null);
    try testing.expect(server._cron_stop_requested.load(.acquire));
}
