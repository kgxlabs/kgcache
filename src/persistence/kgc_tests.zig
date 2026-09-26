const std = @import("std");
const Snapshot = @import("snapshot_interface.zig");
const object = @import("../object.zig");
const time = @import("../time.zig");
const KgcEncoder = @import("../codec/kgc_encoder.zig");
const PersistenceState = @import("../persistence_state.zig");
const logging = @import("../logger.zig");
const KgcBackend = @import("kgc.zig");
const init = KgcBackend.init;
const InitError = KgcBackend.InitError;

test "init rejects a path without the .kgc extension" {
    const testing = std.testing;
    var persistence_state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });

    try testing.expectError(InitError.InvalidExtension, init(testing.io, testing.allocator, &persistence_state, "dump.rdb"));
    try testing.expectError(InitError.InvalidExtension, init(testing.io, testing.allocator, &persistence_state, "dump"));
    try testing.expectError(InitError.InvalidExtension, init(testing.io, testing.allocator, &persistence_state, "dump.kgcx"));
}

test "init accepts a path with the .kgc extension" {
    const testing = std.testing;
    var persistence_state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });

    _ = try init(testing.io, testing.allocator, &persistence_state, "dump.kgc");
}

test "load does nothing when no .kgc file exists yet" {
    const testing = std.testing;
    const DefaultStorage = @import("../storage/default_storage.zig");

    var backend = DefaultStorage.init(testing.io, testing.allocator);
    var backend_storage = backend.storage();
    defer backend_storage.deinit();

    var persistence_state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });
    var backend_instance = try init(testing.io, testing.allocator, &persistence_state, "missing-on-purpose.kgc");
    try backend_instance.snapshot().load(&.{backend_storage});

    var tx = try backend_storage.begin();
    defer tx.end();
    try testing.expectEqual(0, backend_storage.size());
}

test "load rejects a file that isn't a valid .kgc dump" {
    const testing = std.testing;
    const DefaultStorage = @import("../storage/default_storage.zig");

    {
        var file = try std.Io.Dir.cwd().createFile(testing.io, "corrupted-on-purpose.kgc", .{});
        defer file.close(testing.io);

        var buffer: [64]u8 = undefined;
        var file_writer = file.writer(testing.io, &buffer);
        try file_writer.interface.writeAll("this is not a valid kgc file at all");
        try file_writer.flush();
    }

    var backend = DefaultStorage.init(testing.io, testing.allocator);
    var backend_storage = backend.storage();
    defer backend_storage.deinit();

    var persistence_state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });
    var backend_instance = try init(testing.io, testing.allocator, &persistence_state, "corrupted-on-purpose.kgc");
    try testing.expectError(error.InvalidMagic, backend_instance.snapshot().load(&.{backend_storage}));
}

test "a successful save replaces the previous snapshot" {
    const testing = std.testing;
    const DefaultStorage = @import("../storage/default_storage.zig");
    const path = "scratch-save-replaces-snapshot.kgc";
    const cwd = std.Io.Dir.cwd();

    cwd.deleteFile(testing.io, path) catch {};
    defer cwd.deleteFile(testing.io, path) catch {};

    var source = DefaultStorage.init(testing.io, testing.allocator);
    var source_storage = source.storage();
    defer source_storage.deinit();

    var persistence_state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });
    var backend_instance = try init(testing.io, testing.allocator, &persistence_state, path);

    {
        var tx = try source_storage.begin();
        defer tx.end();
        _ = try source_storage.put("key", .{ .string = "old" }, .{ .expires_at = null });
    }
    try backend_instance.snapshot().save(&.{source_storage});

    {
        var tx = try source_storage.begin();
        defer tx.end();
        _ = try source_storage.put("key", .{ .string = "new" }, .{ .expires_at = null });
    }
    try backend_instance.snapshot().save(&.{source_storage});

    var restored = DefaultStorage.init(testing.io, testing.allocator);
    var restored_storage = restored.storage();
    defer restored_storage.deinit();
    try backend_instance.snapshot().load(&.{restored_storage});

    var tx = try restored_storage.begin();
    defer tx.end();
    const loaded = try restored_storage.get("key") orelse return error.TestUnexpectedResult;
    switch (loaded.value) {
        .string => |value| try testing.expectEqualStrings("new", value),
    }
}

test "save returns SaveAlreadyInProgress when a save is already claimed" {
    const testing = std.testing;
    var persistence_state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });
    var backend_instance = try init(testing.io, testing.allocator, &persistence_state, "already-in-progress-save.kgc");

    {
        var state_tx = try persistence_state.begin();
        defer state_tx.end();
        try testing.expectEqual(PersistenceState.StartDecision.started, persistence_state.tryStartKgc(.immediate));
    }
    defer {
        var state_tx = persistence_state.begin() catch unreachable;
        defer state_tx.end();
        persistence_state.finishKgc();
    }

    try testing.expectError(Snapshot.Error.SaveAlreadyInProgress, backend_instance.snapshot().save(&.{}));
}

test "bgsave returns SaveAlreadyInProgress when a save is already claimed, without forking" {
    const testing = std.testing;
    var persistence_state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });
    var backend_instance = try init(testing.io, testing.allocator, &persistence_state, "already-in-progress-bgsave.kgc");

    {
        var state_tx = try persistence_state.begin();
        defer state_tx.end();
        try testing.expectEqual(PersistenceState.StartDecision.started, persistence_state.tryStartKgc(.immediate));
    }
    defer {
        var state_tx = persistence_state.begin() catch unreachable;
        defer state_tx.end();
        persistence_state.finishKgc();
    }

    try testing.expectError(Snapshot.Error.SaveAlreadyInProgress, backend_instance.snapshot().bgsave(&.{}, .manual));

    // no fork should have happened -- no pid was ever recorded
    var state_tx = try persistence_state.begin();
    defer state_tx.end();
    try testing.expectEqual(PersistenceState.ReapResult.running, persistence_state.reapKgc(time.nowMs(testing.io)).status);
}

test "successful save clears the bgsave cooldown" {
    const testing = std.testing;
    const path = "scratch-save-clears-cooldown.kgc";
    std.Io.Dir.cwd().deleteFile(testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(testing.io, path) catch {};

    var persistence_state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });
    const failure_ms = time.nowMs(testing.io);
    {
        var state_tx = try persistence_state.begin();
        defer state_tx.end();
        persistence_state.startBgsaveCooldown(failure_ms);
    }

    var backend_instance = try init(testing.io, testing.allocator, &persistence_state, path);
    try backend_instance.snapshot().save(&.{});

    var state_tx = try persistence_state.begin();
    defer state_tx.end();
    try testing.expect(persistence_state.bgsaveCooldownElapsed(failure_ms, 5000));
}

test "failed save keeps the bgsave cooldown and releases its claim" {
    const testing = std.testing;
    const parent = "missing-save-parent";
    std.Io.Dir.cwd().deleteTree(testing.io, parent) catch {};

    var persistence_state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });
    const failure_ms = time.nowMs(testing.io);
    {
        var state_tx = try persistence_state.begin();
        defer state_tx.end();
        persistence_state.startBgsaveCooldown(failure_ms);
    }

    var backend_instance = try init(testing.io, testing.allocator, &persistence_state, parent ++ "/dump.kgc");
    try testing.expectError(error.FileNotFound, backend_instance.snapshot().save(&.{}));

    var state_tx = try persistence_state.begin();
    defer state_tx.end();
    try testing.expect(!persistence_state.bgsaveCooldownElapsed(failure_ms, 5000));
    try testing.expectEqual(PersistenceState.StartDecision.started, persistence_state.tryStartKgc(.immediate));
}

test "encoder allocation failure preserves the source error and releases the save claim" {
    const testing = std.testing;
    var failing_allocator = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var persistence_state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });
    var backend_instance = try init(testing.io, failing_allocator.allocator(), &persistence_state, "encoder-allocation-failure.kgc");

    try testing.expectError(error.OutOfMemory, backend_instance.snapshot().save(&.{}));
    var tx = try persistence_state.begin();
    defer tx.end();
    try testing.expectEqual(PersistenceState.StartDecision.started, persistence_state.tryStartKgc(.immediate));
}

test "storage visitor failure keeps the previous snapshot and removes encoder state" {
    const testing = std.testing;
    const DefaultStorage = @import("../storage/default_storage.zig");
    const path = "scratch-visitor-failure.kgc";
    const tmp_path = path ++ ".tmp";
    const cwd = std.Io.Dir.cwd();
    cwd.deleteFile(testing.io, path) catch {};
    cwd.deleteFile(testing.io, tmp_path) catch {};
    defer cwd.deleteFile(testing.io, path) catch {};
    defer cwd.deleteFile(testing.io, tmp_path) catch {};

    var storage_backend = DefaultStorage.init(testing.io, testing.allocator);
    var data_storage = storage_backend.storage();
    defer data_storage.deinit();
    {
        var tx = try data_storage.begin();
        defer tx.end();
        _ = try data_storage.put("key", .{ .string = "old" }, .{ .expires_at = null });
    }

    var persistence_state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });
    var backend_instance = try init(testing.io, testing.allocator, &persistence_state, path);
    try backend_instance.snapshot().save(&.{data_storage});
    const previous = try cwd.readFileAlloc(testing.io, path, testing.allocator, .unlimited);
    defer testing.allocator.free(previous);

    var failing_vtable = data_storage.vtable.*;
    failing_vtable.forEach = struct {
        fn fail(_: *anyopaque, _: *anyopaque, _: *const fn (*anyopaque, []const u8, object.Object, ?time.UnixMs) anyerror!void) anyerror!void {
            return error.TestStorageVisit;
        }
    }.fail;
    var failing_storage = data_storage;
    failing_storage.vtable = &failing_vtable;

    try testing.expectError(error.TestStorageVisit, backend_instance.snapshot().save(&.{failing_storage}));
    try testing.expect(backend_instance._encoder == null);
    const current = try cwd.readFileAlloc(testing.io, path, testing.allocator, .unlimited);
    defer testing.allocator.free(current);
    try testing.expectEqualSlices(u8, previous, current);
    try testing.expectError(error.FileNotFound, cwd.readFileAlloc(testing.io, tmp_path, testing.allocator, .unlimited));

    var tx = try persistence_state.begin();
    defer tx.end();
    try testing.expectEqual(PersistenceState.StartDecision.started, persistence_state.tryStartKgc(.immediate));
}

test "fork failure keeps its source error and releases the background save claim" {
    const testing = std.testing;
    var persistence_state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });
    var backend_instance = try init(testing.io, testing.allocator, &persistence_state, "fork-failure.kgc");
    backend_instance._fork = struct {
        fn fail() anyerror!std.posix.pid_t {
            return error.SystemResources;
        }
    }.fail;

    try testing.expectError(error.SystemResources, backend_instance.snapshot().bgsave(&.{}, .automatic));
    var tx = try persistence_state.begin();
    defer tx.end();
    try testing.expectEqual(PersistenceState.StartDecision.started, persistence_state.tryStartKgc(.immediate));
}

test "background child reports its storage source once through the normal logger" {
    const testing = std.testing;
    const DefaultStorage = @import("../storage/default_storage.zig");

    var storage_backend = DefaultStorage.init(testing.io, testing.allocator);
    var data_storage = storage_backend.storage();
    defer data_storage.deinit();
    {
        var tx = try data_storage.begin();
        defer tx.end();
        _ = try data_storage.put("key", .{ .string = "value" }, .{ .expires_at = null });
    }

    var failing_vtable = data_storage.vtable.*;
    failing_vtable.forEach = struct {
        fn fail(_: *anyopaque, _: *anyopaque, _: *const fn (*anyopaque, []const u8, object.Object, ?time.UnixMs) anyerror!void) anyerror!void {
            return error.TestChildDump;
        }
    }.fail;
    var failing_storage = data_storage;
    failing_storage.vtable = &failing_vtable;

    var fds: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.PipeFailed;
    defer _ = std.c.close(fds[0]);
    const saved_stderr = std.c.dup(std.posix.STDERR_FILENO);
    if (saved_stderr < 0) return error.DupFailed;
    defer {
        _ = std.c.dup2(saved_stderr, std.posix.STDERR_FILENO);
        _ = std.c.close(saved_stderr);
    }
    if (std.c.dup2(fds[1], std.posix.STDERR_FILENO) < 0) return error.DupFailed;

    var persistence_state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });
    var backend_instance = try init(testing.io, testing.allocator, &persistence_state, "child-source-failure.kgc");
    var default_logger = logging.DefaultLogger.init(testing.io);
    backend_instance._logger = default_logger.logger();
    {
        var tx = try data_storage.begin();
        defer tx.end();
        _ = try backend_instance.snapshot().bgsave(&.{failing_storage}, .manual);
    }
    if (std.c.dup2(saved_stderr, std.posix.STDERR_FILENO) < 0) return error.DupFailed;
    _ = std.c.close(fds[1]);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(testing.allocator);
    var buffer: [512]u8 = undefined;
    while (true) {
        const count = std.c.read(fds[0], &buffer, buffer.len);
        if (count < 0) {
            if (std.posix.errno(count) == .INTR) continue;
            return error.PipeReadFailed;
        }
        if (count == 0) break;
        try output.appendSlice(testing.allocator, buffer[0..@intCast(count)]);
    }
    try testing.expectEqual(1, std.mem.count(u8, output.items, "TestChildDump"));

    var result: PersistenceState.KgcReapResult = .{ .status = .running };
    var tries: usize = 0;
    while (result.status == .running) {
        var tx = try persistence_state.begin();
        result = persistence_state.reapKgc(time.nowMs(testing.io));
        if (result.status != .running) persistence_state.finishKgc();
        tx.end();
        tries += 1;
        if (tries > 10_000) return error.ChildNeverReaped;
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    try testing.expectEqual(PersistenceState.ReapResult.failed, result.status);
    try testing.expect(result.report_error == null);
}

test "loading an out-of-range database preserves the decoder visitor error" {
    const testing = std.testing;
    const DefaultStorage = @import("../storage/default_storage.zig");
    const path = "scratch-invalid-db.kgc";
    const cwd = std.Io.Dir.cwd();
    defer cwd.deleteFile(testing.io, path) catch {};

    var encoder = KgcEncoder.init(testing.allocator);
    defer encoder.deinit();
    try encoder.writeHeader();
    try encoder.writeSelectDb(1);
    try encoder.writeEntry("key", .{ .string = "value" }, null);
    try encoder.writeFooter();
    {
        var file = try cwd.createFile(testing.io, path, .{});
        defer file.close(testing.io);
        var buffer: [64]u8 = undefined;
        var writer = file.writer(testing.io, &buffer);
        try writer.interface.writeAll(encoder.bytes());
        try writer.flush();
    }

    var storage_backend = DefaultStorage.init(testing.io, testing.allocator);
    var data_storage = storage_backend.storage();
    defer data_storage.deinit();
    var persistence_state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });
    var backend_instance = try init(testing.io, testing.allocator, &persistence_state, path);

    try testing.expectError(error.InvalidDbIndex, backend_instance.snapshot().load(&.{data_storage}));
    var tx = try data_storage.begin();
    defer tx.end();
    try testing.expectEqual(0, data_storage.size());
}

test "file operation failures preserve source errors and the previous snapshot" {
    const testing = std.testing;
    const path = "scratch-file-failures.kgc";
    const tmp_path = path ++ ".tmp";
    const cwd = std.Io.Dir.cwd();
    cwd.deleteFile(testing.io, path) catch {};
    cwd.deleteFile(testing.io, tmp_path) catch {};
    defer cwd.deleteFile(testing.io, path) catch {};
    defer cwd.deleteFile(testing.io, tmp_path) catch {};

    var persistence_state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });
    var backend_instance = try init(testing.io, testing.allocator, &persistence_state, path);
    try backend_instance.snapshot().save(&.{});
    const previous = try cwd.readFileAlloc(testing.io, path, testing.allocator, .unlimited);
    defer testing.allocator.free(previous);

    const Fail = struct {
        fn create(_: ?*anyopaque, _: std.Io.Dir, _: []const u8, _: std.Io.Dir.CreateFileOptions) std.Io.File.OpenError!std.Io.File {
            return error.AccessDenied;
        }

        fn write(_: ?*anyopaque, _: std.Io.File, _: []const u8, _: []const []const u8, _: usize, _: u64) std.Io.File.WritePositionalError!usize {
            return error.InputOutput;
        }

        fn sync(_: ?*anyopaque, _: std.Io.File) std.Io.File.SyncError!void {
            return error.InputOutput;
        }

        fn rename(_: ?*anyopaque, _: std.Io.Dir, _: []const u8, _: std.Io.Dir, _: []const u8) std.Io.Dir.RenameError!void {
            return error.CrossDevice;
        }
    };
    const stages = [_]enum { create, write, sync, rename }{ .create, .write, .sync, .rename };
    for (stages) |stage| {
        var io_vtable = testing.io.vtable.*;
        const source: anyerror = switch (stage) {
            .create => blk: {
                io_vtable.dirCreateFile = Fail.create;
                break :blk error.AccessDenied;
            },
            .write => blk: {
                io_vtable.fileWritePositional = Fail.write;
                break :blk error.InputOutput;
            },
            .sync => blk: {
                io_vtable.fileSync = Fail.sync;
                break :blk error.InputOutput;
            },
            .rename => blk: {
                io_vtable.dirRename = Fail.rename;
                break :blk error.CrossDevice;
            },
        };
        backend_instance._io = .{ .userdata = testing.io.userdata, .vtable = &io_vtable };
        try testing.expectError(source, backend_instance.snapshot().save(&.{}));

        const current = try cwd.readFileAlloc(testing.io, path, testing.allocator, .unlimited);
        defer testing.allocator.free(current);
        try testing.expectEqualSlices(u8, previous, current);
        try testing.expectError(error.FileNotFound, cwd.readFileAlloc(testing.io, tmp_path, testing.allocator, .unlimited));

        var tx = try persistence_state.begin();
        try testing.expectEqual(PersistenceState.StartDecision.started, persistence_state.tryStartKgc(.immediate));
        persistence_state.finishKgc();
        tx.end();
    }
}

test "snapshot read returns its file source error" {
    const testing = std.testing;
    const DefaultStorage = @import("../storage/default_storage.zig");
    const Fail = struct {
        fn open(_: ?*anyopaque, _: std.Io.Dir, _: []const u8, _: std.Io.Dir.OpenFileOptions) std.Io.File.OpenError!std.Io.File {
            return error.AccessDenied;
        }
    };

    var io_vtable = testing.io.vtable.*;
    io_vtable.dirOpenFile = Fail.open;
    const injected_io: std.Io = .{ .userdata = testing.io.userdata, .vtable = &io_vtable };
    var persistence_state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });
    var backend_instance = try init(injected_io, testing.allocator, &persistence_state, "read-source-failure.kgc");
    var storage_backend = DefaultStorage.init(testing.io, testing.allocator);
    var data_storage = storage_backend.storage();
    defer data_storage.deinit();

    try testing.expectError(error.AccessDenied, backend_instance.snapshot().load(&.{data_storage}));
    var tx = try data_storage.begin();
    defer tx.end();
    try testing.expectEqual(0, data_storage.size());
}

test "successful automatic background save clears cooldown and produces a loadable snapshot" {
    const testing = std.testing;
    const DefaultStorage = @import("../storage/default_storage.zig");

    var backend = DefaultStorage.init(testing.io, testing.allocator);
    var backend_storage = backend.storage();
    defer backend_storage.deinit();

    {
        var tx = try backend_storage.begin();
        defer tx.end();
        _ = try backend_storage.put("foo", .{ .string = "bar" }, .{ .expires_at = null });
    }

    var persistence_state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });
    var backend_instance = try init(testing.io, testing.allocator, &persistence_state, "scratch-bgsave.kgc");
    const failure_ms = time.nowMs(testing.io);

    {
        var state_tx = try persistence_state.begin();
        defer state_tx.end();
        persistence_state.startBgsaveCooldown(failure_ms);
    }
    {
        var tx = try backend_storage.begin();
        defer tx.end();
        _ = try backend_instance.snapshot().bgsave(&.{backend_storage}, .automatic);
    }
    {
        var state_tx = try persistence_state.begin();
        defer state_tx.end();
        try testing.expect(persistence_state.kgcInProgress());
    }

    var result: PersistenceState.KgcReapResult = .{ .status = .running };
    var tries: usize = 0;
    while (result.status == .running) {
        var state_tx = try persistence_state.begin();
        result = persistence_state.reapKgc(failure_ms);
        if (result.status != .running) persistence_state.finishKgc();
        state_tx.end();
        tries += 1;
        if (tries > 10_000) return error.ChildNeverReaped;
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    try testing.expectEqual(PersistenceState.ReapResult.succeeded, result.status);
    {
        var state_tx = try persistence_state.begin();
        defer state_tx.end();
        try testing.expect(!persistence_state.kgcInProgress());
        try testing.expect(persistence_state.bgsaveCooldownElapsed(failure_ms, 5000));
    }

    var fresh = DefaultStorage.init(testing.io, testing.allocator);
    var fresh_storage = fresh.storage();
    defer fresh_storage.deinit();

    try backend_instance.snapshot().load(&.{fresh_storage});

    var tx = try fresh_storage.begin();
    defer tx.end();
    const loaded = try fresh_storage.get("foo") orelse return error.TestUnexpectedResult;
    switch (loaded.value) {
        .string => |str| try testing.expectEqualStrings("bar", str),
    }
}
