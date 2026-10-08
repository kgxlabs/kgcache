const std = @import("std");
const storage = @import("storage.zig");
const store = @import("store.zig");
const object = @import("object.zig");
const Request = @import("commander/request.zig");
const persistence = @import("persistence.zig");
const PersistenceState = @import("persistence_state.zig");
const Manifest = @import("persistence/manifest.zig");
const Config = @import("config.zig");
const time = @import("time.zig");
const logging = @import("logger.zig");
const Server = @import("server.zig");

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
        .dispatchPendingBgsave = dispatchPendingBgsave,
        .dispatchPendingAofRewrite = dispatchPendingAofRewrite,
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

    fn bgsave(ptr: *anyopaque, origin: store.Store.TriggerOrigin) anyerror!PersistenceState.BackgroundStartOutcome {
        const self: *BlockingStore = @ptrCast(@alignCast(ptr));
        return self.inner.bgsave(origin);
    }

    fn bgrewriteaof(ptr: *anyopaque, origin: store.Store.TriggerOrigin) anyerror!PersistenceState.BackgroundStartOutcome {
        const self: *BlockingStore = @ptrCast(@alignCast(ptr));
        return self.inner.bgrewriteaof(origin);
    }

    fn dispatchPendingBgsave(ptr: *anyopaque) anyerror!bool {
        const self: *BlockingStore = @ptrCast(@alignCast(ptr));
        return self.inner.dispatchPendingBgsave();
    }

    fn dispatchPendingAofRewrite(ptr: *anyopaque) anyerror!bool {
        const self: *BlockingStore = @ptrCast(@alignCast(ptr));
        return self.inner.dispatchPendingAofRewrite();
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

test "snapshot and AOF persistence use relative and absolute dir" {
    const testing = std.testing;
    for ([_]bool{ false, true }) |absolute_dir| {
        for ([_]bool{ false, true }) |append_only| {
            var tmp = testing.tmpDir(.{});
            defer tmp.cleanup();
            const relative_dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
            defer testing.allocator.free(relative_dir);
            var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const absolute_len = try tmp.dir.realPath(testing.io, &path_buffer);
            const config: Config = .{
                .dir = if (absolute_dir) path_buffer[0..absolute_len] else relative_dir,
                .dbfilename = if (absolute_dir) "custom.kgc" else "dump.kgc",
                .append_only = append_only,
                .append_dirname = "history",
                .append_filename = "journal.aof",
                .append_fsync = .always,
                .num_databases = 1,
            };

            {
                const server = try Server.create(testing.io, testing.allocator, config, logging.NoopLogger.logger());
                defer server.destroy() catch unreachable;
                _ = try server._store.set(.{
                    .key = "persistent",
                    .value = "snapshot-value",
                    .condition = null,
                    .expires_at = null,
                    .keepttl = false,
                    .response = null,
                }, 0);
                try server._store.save();
                if (append_only) {
                    _ = try server._store.set(.{
                        .key = "persistent",
                        .value = "aof-value",
                        .condition = null,
                        .expires_at = null,
                        .keepttl = false,
                        .response = null,
                    }, 0);
                }
            }

            try tmp.dir.access(testing.io, config.dbfilename, .{});
            if (append_only) {
                try tmp.dir.access(testing.io, "history/journal.aof.manifest", .{});
                try tmp.dir.access(testing.io, "history/journal.aof.1.incr", .{});
                try tmp.dir.writeFile(testing.io, .{
                    .sub_path = "history/journal.aof.99.base",
                    .data = "interrupted rewrite",
                });
            } else {
                try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "history", .{}));
            }

            const restarted = try Server.create(testing.io, testing.allocator, config, logging.NoopLogger.logger());
            defer restarted.destroy() catch unreachable;
            var loaded = try restarted._store.get("persistent", 0) orelse return error.TestUnexpectedResult;
            defer loaded.deinit();
            try testing.expectEqualStrings(if (append_only) "aof-value" else "snapshot-value", loaded.value.string);
            if (append_only) {
                try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "history/journal.aof.99.base", .{}));
            }
        }
    }
}

test "create rejects a missing persistence directory without creating it" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const missing_dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/missing", .{tmp.sub_path});
    defer testing.allocator.free(missing_dir);

    for ([_]bool{ false, true }) |append_only| {
        try testing.expectError(error.FileNotFound, Server.create(
            testing.io,
            testing.allocator,
            .{ .dir = missing_dir, .append_only = append_only },
            logging.NoopLogger.logger(),
        ));
        try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "missing", .{}));
    }
}

test "create validates persistence names supplied directly in Config" {
    const testing = std.testing;
    for ([_]Config{
        .{ .dir = "" },
        .{ .dbfilename = "../dump.kgc" },
        .{ .dbfilename = "dump.rdb" },
        .{ .append_dirname = "../aof" },
    }) |config| {
        try testing.expectError(error.InvalidValue, Server.create(testing.io, testing.allocator, config, logging.NoopLogger.logger()));
    }
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
    config.dbfilename = snapshot_path;

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
    config.dbfilename = snapshot_path;

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

test "startup recovers an unfinished final command and resumes writing at the safe offset" {
    const testing = std.testing;
    const cwd = std.Io.Dir.cwd();
    const dirname = "scratch-server-aof-recovered-tail";
    const good = "*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$5\r\nvalue\r\n";
    const tail = "*3\r\n$3\r\nSET\r\n$3\r\nbad\r\n$5\r\npar";
    cwd.deleteTree(testing.io, dirname) catch {};
    defer cwd.deleteTree(testing.io, dirname) catch {};
    try writeReplayFixture(testing.io, dirname, good ++ tail);

    var config = Config.default();
    config.append_only = true;
    config.append_dirname = dirname;
    config.aof_load_truncated = true;
    config.append_fsync = .always;
    var dir = try cwd.openDir(testing.io, dirname, .{});
    defer dir.close(testing.io);

    {
        var logger = logging.TestLogger.init();
        const server = try Server.create(testing.io, testing.allocator, config, logger.logger());
        defer server.destroy() catch unreachable;
        var loaded = try server._store.get("key", 0) orelse return error.TestUnexpectedResult;
        defer loaded.deinit();
        try testing.expectEqualStrings("value", loaded.value.string);
        try testing.expectEqual(null, try server._store.get("bad", 0));
        try testing.expectEqual(@as(u64, good.len), server._aof.?._file_offset);
        try testing.expectEqual(@as(u64, good.len), server._aof.?._incr_bytes);
        try testing.expect(!server._aof.?._loading);
        try testing.expectEqual(0, server._persistence_state.captureSnapshotChangeCount());
        const recovered = try dir.readFileAlloc(testing.io, "appendonly.aof.1.incr", testing.allocator, .unlimited);
        defer testing.allocator.free(recovered);
        try testing.expectEqualStrings(good, recovered);
        var warnings: usize = 0;
        for (logger.recordedEvents()) |event| {
            if (std.mem.startsWith(u8, event.message(), "AOF recovery:")) {
                try testing.expectEqual(logging.Logger.Level.warn, event.level.?);
                warnings += 1;
            }
        }
        try testing.expectEqual(1, warnings);

        _ = try server._store.set(.{
            .key = "after-recovery",
            .value = "writable",
            .condition = null,
            .expires_at = null,
            .keepttl = false,
            .response = null,
        }, 0);
    }

    const server = try Server.create(testing.io, testing.allocator, config, logging.NoopLogger.logger());
    defer server.destroy() catch unreachable;
    var loaded = try server._store.get("after-recovery", 0) orelse return error.TestUnexpectedResult;
    defer loaded.deinit();
    try testing.expectEqualStrings("writable", loaded.value.string);
    try testing.expectEqual(null, try server._store.get("bad", 0));
    const contents = try dir.readFileAlloc(testing.io, "appendonly.aof.1.incr", testing.allocator, .unlimited);
    defer testing.allocator.free(contents);
    try testing.expect(std.mem.startsWith(u8, contents, good));
    try testing.expect(contents.len > good.len);
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

test "malformed AOF headers and terminators fail startup without tail repair" {
    const testing = std.testing;
    const cwd = std.Io.Dir.cwd();
    const dirname = "scratch-server-aof-malformed-input";
    cwd.deleteTree(testing.io, dirname) catch {};
    defer cwd.deleteTree(testing.io, dirname) catch {};
    try writeReplayFixture(testing.io, dirname, "");

    var dir = try cwd.openDir(testing.io, dirname, .{});
    defer dir.close(testing.io);
    var config = Config.default();
    config.append_only = true;
    config.append_dirname = dirname;
    config.aof_load_truncated = true;

    const good = "*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$5\r\nvalue\r\n";
    const invalid = [_]struct { bytes: []const u8, err: anyerror }{
        .{ .bytes = "*x", .err = error.InvalidArrayLength },
        .{ .bytes = "*0\r\n", .err = error.EmptyArray },
        .{ .bytes = "*-1\r\n", .err = error.InvalidArrayLength },
        .{ .bytes = "*1\rX", .err = error.InvalidLineEnding },
        .{ .bytes = "*1\r\n$-", .err = error.InvalidBulkLength },
        .{ .bytes = "*1\r\n$x", .err = error.InvalidBulkLength },
        .{ .bytes = "*1\r\n$9223372036854775808", .err = error.LengthOverflow },
        .{ .bytes = "*1\r\n:", .err = error.ExpectedBulkString },
        .{ .bytes = "*1\r\n$1\r\nxX", .err = error.InvalidBulkTerminator },
    };
    for (invalid) |item| {
        for ([_][]const u8{ "", good }) |prefix| {
            for ([_][]const u8{ "", good }) |suffix| {
                var buffer: [256]u8 = undefined;
                const contents = try std.fmt.bufPrint(&buffer, "{s}{s}{s}", .{ prefix, item.bytes, suffix });
                try dir.writeFile(testing.io, .{ .sub_path = "appendonly.aof.1.incr", .data = contents });
                var logger = logging.TestLogger.init();

                try testing.expectError(item.err, Server.create(testing.io, testing.allocator, config, logger.logger()));
                const preserved = try dir.readFileAlloc(testing.io, "appendonly.aof.1.incr", testing.allocator, .unlimited);
                defer testing.allocator.free(preserved);
                try testing.expectEqualStrings(contents, preserved);
                for (logger.recordedEvents()) |event| {
                    try testing.expect(!std.mem.startsWith(u8, event.message(), "AOF recovery:"));
                }
            }
        }
    }
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
