const std = @import("std");
const Snapshot = @import("./snapshot_interface.zig");
const Storage = @import("../storage/interface.zig");
const object = @import("../object.zig");
const time = @import("../time.zig");
const KgcEncoder = @import("../codec/kgc_encoder.zig");
const KgcDecoder = @import("../codec/kgc_decoder.zig");
const PersistenceState = @import("../persistence_state.zig");
const Store = @import("../store/interface.zig");
const logging = @import("../logger.zig");

const KgcBackend = @This();

const vtable: Snapshot.VTable = .{
    .save = save,
    .bgsave = bgsave,
    .load = load,
};

const required_extension = ".kgc";

pub const InitError = error{InvalidExtension};

_io: std.Io,
_allocator: std.mem.Allocator,
_path: []const u8,
// Set for the duration of a single `save()` call: created in `beginDump`,
// appended to in `dumpEntry`, consumed in `endDump`, and cleared in `dump`.
_encoder: ?KgcEncoder = null,
_persistence_state: *PersistenceState,
_logger: logging.Logger = logging.NoopLogger.logger(),
// making a field to make this testable without having to rely on OS to fail
_fork: *const fn () anyerror!std.posix.pid_t = forkProcess,

pub fn init(io: std.Io, allocator: std.mem.Allocator, state: *PersistenceState, path: []const u8) InitError!KgcBackend {
    if (!std.mem.endsWith(u8, path, required_extension)) return InitError.InvalidExtension;

    return .{
        ._io = io,
        ._allocator = allocator,
        ._path = path,
        ._persistence_state = state,
    };
}

pub fn snapshot(self: *KgcBackend) Snapshot {
    return .{
        .ptr = self,
        .vtable = &vtable,
    };
}

// only hold short lock session so we dont hold the lock while I/O
pub fn save(ptr: *anyopaque, storages: []const Storage) anyerror!void {
    const self: *KgcBackend = @ptrCast(@alignCast(ptr));

    {
        var state_tx = try self._persistence_state.begin();
        defer state_tx.end();
        if (!self._persistence_state.tryStartKgc()) return Snapshot.Error.SaveAlreadyInProgress;
    }

    errdefer {
        var state_tx = self._persistence_state.beginUncancelable();
        defer state_tx.end();
        self._persistence_state.finishKgc();
    }

    try self.dump(storages);
    var state_tx = try self._persistence_state.begin();
    defer state_tx.end();

    const captured_change_count = self._persistence_state.captureSnapshotChangeCount();
    try self._persistence_state.markSaved(captured_change_count, time.nowMs(self._io));
    self._persistence_state.clearBgsaveCooldown();
    self._persistence_state.finishKgc();
}

// only hold short lock session so we dont hold the lock while fork
// Finishing this does not mean, saving succeeded.
// It just means forking completed
pub fn bgsave(ptr: *anyopaque, storages: []const Storage, origin: Store.TriggerOrigin) anyerror!PersistenceState.BackgroundStartOutcome {
    const self: *KgcBackend = @ptrCast(@alignCast(ptr));

    {
        var state_tx = try self._persistence_state.begin();
        defer state_tx.end();
        if (!self._persistence_state.tryStartKgc()) return Snapshot.Error.SaveAlreadyInProgress;
    }

    // NOTE: the placement is important. This way A busy return would not run finishKgc() and clear another operation’s active state
    errdefer {
        var tx = self._persistence_state.beginUncancelable();
        defer tx.end();
        self._persistence_state.finishKgc();
    }

    const pid = try self._fork();

    if (pid == 0) {
        // The child inherits stdin, stdout, and stderr from the parent.
        // It needs no stdin. Close stdout so tests waiting for output can finish.
        // Keep stderr open to report child errors.
        _ = std.c.close(std.posix.STDIN_FILENO);
        _ = std.c.close(std.posix.STDOUT_FILENO);

        self.dump(storages) catch |err| {
            // TODO: Send the source error to the parent through a pipe so the
            // child does not lock logger state copied during fork.
            self._logger.err("kgc: background save failed", err, @errorReturnTrace());
            std.c._exit(1);
        };
        // never reutrn . do not fall back into caller's connection loop since this is a child process now
        // using _exit to sidestep clearing the buffered data (at the time of fork) completely
        std.c._exit(0);
    }

    // Fork succeeded, so cancellation must not leave the child untracked.
    var state_tx = self._persistence_state.beginUncancelable();
    defer state_tx.end();

    const snapshot_change_count = self._persistence_state.captureSnapshotChangeCount();
    self._persistence_state.setInFlightKgcSave(.{
        .pid = pid,
        .captured_change_count = snapshot_change_count,
        .origin = origin,
    });

    return .started;
}

fn forkProcess() anyerror!std.posix.pid_t {
    const rc = std.posix.system.fork();
    return switch (std.posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .AGAIN => error.SystemResources,
        .NOMEM => error.OutOfMemory,
        else => error.Unexpected,
    };
}

fn dump(self: *KgcBackend, storages: []const Storage) anyerror!void {
    try self.beginDump();
    defer {
        if (self._encoder) |*encoder| encoder.deinit();
        self._encoder = null;
    }
    for (storages, 0..) |storage, db_index| {
        // a database with nothing in it gets no `SELECTDB`
        // section at all, rather than an empty one.
        if (storage.size() == 0) continue;

        try self.selectDb(@intCast(db_index));
        try storage.forEach(self, visitEntry);
    }
    try self.endDump();
}

fn visitEntry(ctx: *anyopaque, key: []const u8, value: object.Object, exp: ?time.UnixMs) anyerror!void {
    const self: *KgcBackend = @ptrCast(@alignCast(ctx));
    try self.dumpEntry(key, value, exp);
}

fn beginDump(self: *KgcBackend) !void {
    var encoder = KgcEncoder.init(self._allocator);
    errdefer encoder.deinit();

    try encoder.writeHeader();
    self._encoder = encoder;
}

fn selectDb(self: *KgcBackend, db_index: u32) !void {
    try self._encoder.?.writeSelectDb(db_index);
}

fn dumpEntry(self: *KgcBackend, key: []const u8, value: object.Object, exp: ?time.UnixMs) !void {
    try self._encoder.?.writeEntry(key, value, exp);
}

fn endDump(self: *KgcBackend) !void {
    var encoder = &self._encoder.?;

    try encoder.writeFooter();

    const cwd = std.Io.Dir.cwd();
    // write and fsync to temporary dump file
    const tmp_file_name = try self.tmpFileName();
    defer self._allocator.free(tmp_file_name);
    // Keep the original save error if removing the temporary file also fails.
    errdefer cwd.deleteFile(self._io, tmp_file_name) catch {};

    // NOTE: we must put this into separate block
    // because closing first is clearer even though POSIX permits renaming an open file.
    // And this will save headaches for futures bugs on platforms like Window
    {
        var file = try cwd.createFile(self._io, tmp_file_name, .{});
        defer file.close(self._io);

        try self.writeToDisk(file, encoder.bytes());
        try file.sync(self._io);
    }

    try cwd.rename(tmp_file_name, cwd, self._path, self._io);

    // TODO: we still need to sync parent dir because power loss immediately after rename could lose new dir metdata change (aka rename)
    // but Zig (0.16.0) does not have directory level sync.
    // This issue is tracked here: https://github.com/kgxlabs/kgcache/issues/64
}

fn writeToDisk(self: *KgcBackend, file: std.Io.File, data: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var file_writer = file.writer(self._io, &buffer);
    try file_writer.interface.writeAll(data);
    try file_writer.flush();
}

fn tmpFileName(self: *KgcBackend) ![]u8 {
    return std.fmt.allocPrint(self._allocator, "{s}.tmp", .{self._path});
}

pub fn load(ptr: *anyopaque, storages: []const Storage) anyerror!void {
    const self: *KgcBackend = @ptrCast(@alignCast(ptr));

    // No file yet is the normal first-boot case, not a failure: start empty.
    const data = self.readFromDisk() catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer self._allocator.free(data);

    var ctx: LoadContext = .{ .storages = storages };
    try KgcDecoder.decode(data, &ctx, applyRecord);
}

const LoadContext = struct {
    storages: []const Storage,
};

fn applyRecord(ctx: *anyopaque, record: KgcDecoder.Record) anyerror!void {
    const self: *LoadContext = @ptrCast(@alignCast(ctx));
    if (record.db_index >= self.storages.len) return error.InvalidDbIndex;

    const target = self.storages[record.db_index];
    var tx = try target.begin();
    defer tx.end();

    _ = try target.put(record.key, record.value, .{ .expires_at = record.exp });
}

fn readFromDisk(self: *KgcBackend) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(self._io, self._path, self._allocator, .unlimited);
}

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
        try testing.expect(persistence_state.tryStartKgc());
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
        try testing.expect(persistence_state.tryStartKgc());
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
    try testing.expect(persistence_state.tryStartKgc());
}

test "encoder allocation failure preserves the source error and releases the save claim" {
    const testing = std.testing;
    var failing_allocator = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var persistence_state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });
    var backend_instance = try init(testing.io, failing_allocator.allocator(), &persistence_state, "encoder-allocation-failure.kgc");

    try testing.expectError(error.OutOfMemory, backend_instance.snapshot().save(&.{}));
    var tx = try persistence_state.begin();
    defer tx.end();
    try testing.expect(persistence_state.tryStartKgc());
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
    try testing.expect(persistence_state.tryStartKgc());
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
    try testing.expect(persistence_state.tryStartKgc());
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
        try testing.expect(persistence_state.tryStartKgc());
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
