const std = @import("std");
const storage = @import("storage.zig");
const store = @import("store.zig");
const object = @import("object.zig");
const Request = @import("commander/request.zig");
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

const BlockingStore = struct {
    inner: store.Store,
    io: std.Io,
    command_entered: std.Io.Event = .unset,
    release_command: std.Io.Event = .unset,
    deinit_called: std.atomic.Value(bool) = .init(false),

    fn interface(self: *BlockingStore) store.Store {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = store.Store.VTable{
        .get = get,
        .set = set,
        .remove = remove,
        .dbsize = dbsize,
        .numDatabases = numDatabases,
        .save = save,
        .bgsave = bgsave,
        .bgrewriteaof = bgrewriteaof,
        .deinit = deinit,
    };

    fn get(ptr: *anyopaque, key: []const u8, db_index: u32) anyerror!?object.Owned {
        const self: *BlockingStore = @ptrCast(@alignCast(ptr));
        return self.inner.get(key, db_index);
    }

    fn set(ptr: *anyopaque, request: Request.SetRequest, db_index: u32) anyerror!store.Store.SetResult {
        const self: *BlockingStore = @ptrCast(@alignCast(ptr));
        return self.inner.set(request, db_index);
    }

    fn remove(ptr: *anyopaque, key: []const u8, db_index: u32) anyerror!store.Store.RemoveResult {
        const self: *BlockingStore = @ptrCast(@alignCast(ptr));
        return self.inner.remove(key, db_index);
    }

    fn dbsize(ptr: *anyopaque, db_index: u32) anyerror!u32 {
        const self: *BlockingStore = @ptrCast(@alignCast(ptr));
        self.command_entered.set(self.io);
        self.release_command.waitUncancelable(self.io);
        return self.inner.dbsize(db_index);
    }

    fn numDatabases(ptr: *anyopaque) u32 {
        const self: *BlockingStore = @ptrCast(@alignCast(ptr));
        return self.inner.numDatabases();
    }

    fn save(ptr: *anyopaque) anyerror!void {
        const self: *BlockingStore = @ptrCast(@alignCast(ptr));
        return self.inner.save();
    }

    fn bgsave(ptr: *anyopaque, origin: store.Store.TriggerOrigin) anyerror!void {
        const self: *BlockingStore = @ptrCast(@alignCast(ptr));
        return self.inner.bgsave(origin);
    }

    fn bgrewriteaof(ptr: *anyopaque, origin: store.Store.TriggerOrigin) anyerror!void {
        const self: *BlockingStore = @ptrCast(@alignCast(ptr));
        return self.inner.bgrewriteaof(origin);
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *BlockingStore = @ptrCast(@alignCast(ptr));
        self.deinit_called.store(true, .release);
        self.inner.deinit();
    }
};

const BlockingCommandIo = struct {
    base_io: std.Io,
    request_sent: std.atomic.Value(bool) = .init(false),
    shutdown_calls: std.atomic.Value(usize) = .init(0),
    close_calls: std.atomic.Value(usize) = .init(0),
    shutdown_called: std.Io.Event = .unset,
    vtable: std.Io.VTable = undefined,

    const request = "*1\r\n$6\r\nDBSIZE\r\n";

    fn io(self: *BlockingCommandIo) std.Io {
        self.vtable = self.base_io.vtable.*;
        self.vtable.netRead = netRead;
        self.vtable.netWrite = netWrite;
        self.vtable.netClose = netClose;
        self.vtable.netShutdown = netShutdown;
        return .{ .userdata = self, .vtable = &self.vtable };
    }

    fn stream() std.Io.net.Stream {
        return .{ .socket = .{ .handle = 1, .address = undefined } };
    }

    fn netRead(
        userdata: ?*anyopaque,
        _: std.Io.net.Socket.Handle,
        data: [][]u8,
    ) std.Io.net.Stream.Reader.Error!usize {
        const self: *BlockingCommandIo = @ptrCast(@alignCast(userdata));
        if (self.request_sent.swap(true, .acq_rel)) return 0;
        @memcpy(data[0][0..request.len], request);
        return request.len;
    }

    fn netWrite(
        _: ?*anyopaque,
        _: std.Io.net.Socket.Handle,
        header: []const u8,
        data: []const []const u8,
        splat: usize,
    ) std.Io.net.Stream.Writer.Error!usize {
        var bytes_written = header.len;
        for (data[0 .. data.len - 1]) |part| bytes_written += part.len;
        if (splat > 0) bytes_written += data[data.len - 1].len * splat;
        return bytes_written;
    }

    fn netShutdown(
        userdata: ?*anyopaque,
        _: std.Io.net.Socket.Handle,
        _: std.Io.net.ShutdownHow,
    ) std.Io.net.ShutdownError!void {
        const self: *BlockingCommandIo = @ptrCast(@alignCast(userdata));
        _ = self.shutdown_calls.fetchAdd(1, .acq_rel);
        self.shutdown_called.set(self.base_io);
    }

    fn netClose(userdata: ?*anyopaque, handles: []const std.Io.net.Socket.Handle) void {
        const self: *BlockingCommandIo = @ptrCast(@alignCast(userdata));
        _ = self.close_calls.fetchAdd(handles.len, .acq_rel);
    }
};

test "create builds the full object graph and destroy leaks nothing" {
    const testing = std.testing;

    const server = try Server.create(testing.io, testing.allocator, Config.default(), logging.NoopLogger.logger());
    try server.destroy();
}

test "server destroy keeps Store alive until a connection command finishes" {
    const testing = std.testing;
    const server = try Server.create(testing.io, testing.allocator, Config.default(), logging.NoopLogger.logger());
    var server_destroyed = false;
    defer if (!server_destroyed) server.destroy() catch unreachable;

    var blocking_store: BlockingStore = .{ .inner = server._store, .io = testing.io };
    server._store = blocking_store.interface();
    defer blocking_store.release_command.set(testing.io);

    var connection_io: BlockingCommandIo = .{ .base_io = testing.io };
    server._connection_manager._io = connection_io.io();
    try server._connection_manager.start(BlockingCommandIo.stream());
    blocking_store.command_entered.waitUncancelable(testing.io);

    const DestroyContext = struct {
        server: *Server,
        result: ?anyerror = null,

        fn run(self: *@This()) void {
            self.server.destroy() catch |err| {
                self.result = err;
            };
        }
    };
    var destroy_context: DestroyContext = .{ .server = server };
    const destroy_thread = try std.Thread.spawn(.{}, DestroyContext.run, .{&destroy_context});

    connection_io.shutdown_called.waitUncancelable(testing.io);
    const store_was_alive_during_command = !blocking_store.deinit_called.load(.acquire);
    blocking_store.release_command.set(testing.io);
    destroy_thread.join();
    server_destroyed = true;

    try testing.expect(store_was_alive_during_command);
    try testing.expect(blocking_store.deinit_called.load(.acquire));
    try testing.expectEqual(null, destroy_context.result);
    try testing.expectEqual(1, connection_io.shutdown_calls.load(.acquire));
    try testing.expectEqual(1, connection_io.close_calls.load(.acquire));
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

fn writeKgcSnapshotWithFooBar(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
    var backend = storage.DefaultStorage.init(io, allocator);
    var backend_storage = backend.storage();
    defer backend_storage.deinit();

    var persistence_state = PersistenceState.init(io, .{ .mutual_exclusive = false });
    var kgc_backend = try persistence.KgcPersistence.init(io, allocator, &persistence_state, path);
    var tx = try backend_storage.begin();
    defer tx.end();
    _ = try backend_storage.put("foo", .{ .string = "bar" }, .{ .expires_at = null });
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

    const server = try Server.create(testing.io, testing.allocator, config, logging.NoopLogger.logger());
    try testing.expect(server._aof == null);
    try server.destroy();

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

    const server = try Server.create(testing.io, testing.allocator, config, logging.NoopLogger.logger());
    try testing.expect(server._aof != null);

    var dir = try cwd.openDir(testing.io, dirname, .{});
    dir.close(testing.io);

    try server.destroy();
}

test "destroy releases server state after AOF close failure" {
    const testing = std.testing;
    const cwd = std.Io.Dir.cwd();
    const dirname = "scratch-server-aof-close-failure";

    cwd.deleteTree(testing.io, dirname) catch {};
    defer cwd.deleteTree(testing.io, dirname) catch {};

    var config = Config.default();
    config.append_only = true;
    config.append_dirname = dirname;

    const server = try Server.create(testing.io, testing.allocator, config, logging.NoopLogger.logger());
    const aof = &server._aof.?;
    const file = aof._file orelse return error.TestUnexpectedResult;
    file.close(testing.io);
    aof._file = null;

    try testing.expectError(error.MissingLiveAofFile, server.destroy());
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

    const server = try Server.create(testing.io, testing.allocator, config, logging.NoopLogger.logger());
    defer server.destroy() catch unreachable;

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

    const server = try Server.create(testing.io, testing.allocator, config, logging.NoopLogger.logger());
    defer server.destroy() catch unreachable;

    var loaded = try server._store.get("foo", 0) orelse return error.TestUnexpectedResult;
    defer loaded.deinit();
    switch (loaded.value) {
        .string => |str| try testing.expectEqualStrings("bar", str),
    }
}

fn writeReplayFixture(io: std.Io, dirname: []const u8, contents: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDir(io, dirname, .default_dir);
    var dir = try cwd.openDir(io, dirname, .{});
    defer dir.close(io);

    try dir.writeFile(io, .{
        .sub_path = "appendonly.aof.manifest",
        .data = "file appendonly.aof.1.incr seq 1 type i\n",
    });
    try dir.writeFile(io, .{
        .sub_path = "appendonly.aof.1.incr",
        .data = contents,
    });
}

test "replay does not append to the file it is replaying" {
    const testing = std.testing;
    const cwd = std.Io.Dir.cwd();
    const dirname = "scratch-server-aof-replay-no-append";
    const command = "*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$5\r\nvalue\r\n";

    cwd.deleteTree(testing.io, dirname) catch {};
    defer cwd.deleteTree(testing.io, dirname) catch {};
    try writeReplayFixture(testing.io, dirname, command);

    var config = Config.default();
    config.append_only = true;
    config.append_dirname = dirname;

    const server = try Server.create(testing.io, testing.allocator, config, logging.NoopLogger.logger());
    defer server.destroy() catch unreachable;

    var dir = try cwd.openDir(testing.io, dirname, .{});
    defer dir.close(testing.io);
    const file = try dir.openFile(testing.io, "appendonly.aof.1.incr", .{});
    defer file.close(testing.io);
    try testing.expectEqual(@as(u64, command.len), try file.length(testing.io));
}

test "replay leaves the dirty count at zero" {
    const testing = std.testing;
    const cwd = std.Io.Dir.cwd();
    const dirname = "scratch-server-aof-replay-clean";

    cwd.deleteTree(testing.io, dirname) catch {};
    defer cwd.deleteTree(testing.io, dirname) catch {};
    try writeReplayFixture(
        testing.io,
        dirname,
        "*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$5\r\nvalue\r\n",
    );

    var config = Config.default();
    config.append_only = true;
    config.append_dirname = dirname;

    const server = try Server.create(testing.io, testing.allocator, config, logging.NoopLogger.logger());
    defer server.destroy() catch unreachable;

    try testing.expectEqual(0, server._persistence_state.captureSnapshotChangeCount());
}

test "failed AOF replay frees loaded entries and leaves orphaned files untouched" {
    const testing = std.testing;
    const cwd = std.Io.Dir.cwd();
    const dirname = "scratch-server-aof-failed-replay-keeps-orphans";

    cwd.deleteTree(testing.io, dirname) catch {};
    defer cwd.deleteTree(testing.io, dirname) catch {};
    try writeReplayFixture(
        testing.io,
        dirname,
        "*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$5\r\nvalue\r\n" ++
            "*1\r\n$7\r\nUNKNOWN\r\n",
    );

    var dir = try cwd.openDir(testing.io, dirname, .{});
    defer dir.close(testing.io);
    try dir.writeFile(testing.io, .{
        .sub_path = "appendonly.aof.2.base",
        .data = "rewrite evidence",
    });

    var config = Config.default();
    config.append_only = true;
    config.append_dirname = dirname;

    try testing.expectError(
        error.UnknownCommand,
        Server.create(testing.io, testing.allocator, config, logging.NoopLogger.logger()),
    );
    try dir.access(testing.io, "appendonly.aof.2.base", .{});
}

test "manifest without incrementals is repaired and server remains writable" {
    const testing = std.testing;
    const cwd = std.Io.Dir.cwd();
    const dirname = "scratch-server-aof-repair-no-incr";

    cwd.deleteTree(testing.io, dirname) catch {};
    defer cwd.deleteTree(testing.io, dirname) catch {};
    try cwd.createDir(testing.io, dirname, .default_dir);

    var dir = try cwd.openDir(testing.io, dirname, .{});
    defer dir.close(testing.io);
    try dir.writeFile(testing.io, .{
        .sub_path = "appendonly.aof.manifest",
        .data = "file appendonly.aof.2.base seq 2 type b\n",
    });
    try dir.writeFile(testing.io, .{
        .sub_path = "appendonly.aof.2.base",
        .data = "",
    });

    var config = Config.default();
    config.append_only = true;
    config.append_dirname = dirname;
    config.append_fsync = .always;

    const server = try Server.create(testing.io, testing.allocator, config, logging.NoopLogger.logger());
    defer server.destroy() catch unreachable;

    const repaired_manifest = try Manifest.read(
        testing.io,
        testing.allocator,
        dir,
        "appendonly.aof.manifest",
    ) orelse return error.TestUnexpectedResult;
    defer repaired_manifest.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), repaired_manifest.incrs.len);
    try testing.expectEqual(@as(u32, 3), repaired_manifest.incrs[0].seq);
    try testing.expectEqualStrings("appendonly.aof.3.incr", repaired_manifest.incrs[0].name);

    _ = try server._store.set(.{
        .key = "after-repair",
        .value = "writable",
        .condition = null,
        .expires_at = null,
        .keepttl = false,
        .response = null,
    }, 0);

    const live_file = try dir.openFile(testing.io, "appendonly.aof.3.incr", .{});
    defer live_file.close(testing.io);
    try testing.expect((try live_file.length(testing.io)) > 0);
}

test "writes survive a simulated restart" {
    const testing = std.testing;
    const cwd = std.Io.Dir.cwd();
    const dirname = "scratch-server-aof-restart";

    cwd.deleteTree(testing.io, dirname) catch {};
    defer cwd.deleteTree(testing.io, dirname) catch {};

    var config = Config.default();
    config.append_only = true;
    config.append_dirname = dirname;
    config.append_fsync = .always;

    const expires_at = time.nowMs(testing.io) + 60_000;
    {
        const first = try Server.create(testing.io, testing.allocator, config, logging.NoopLogger.logger());
        _ = try first._store.set(.{
            .key = "persistent",
            .value = "one",
            .condition = null,
            .expires_at = null,
            .keepttl = false,
            .response = null,
        }, 0);
        _ = try first._store.set(.{
            .key = "expiring",
            .value = "two",
            .condition = null,
            .expires_at = expires_at,
            .keepttl = false,
            .response = null,
        }, 1);
        try first.destroy();
    }

    const second = try Server.create(testing.io, testing.allocator, config, logging.NoopLogger.logger());
    defer second.destroy() catch unreachable;

    var persistent = try second._store.get("persistent", 0) orelse return error.TestUnexpectedResult;
    defer persistent.deinit();
    try testing.expectEqualStrings("one", persistent.value.string);
    var expiring = try second._store.get("expiring", 1) orelse return error.TestUnexpectedResult;
    defer expiring.deinit();
    try testing.expectEqualStrings("two", expiring.value.string);

    var tx = try second._data_storages[1].begin();
    defer tx.end();
    const expiration = try second._data_storages[1].getExp("expiring") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(expires_at, expiration.expires_at);
}
