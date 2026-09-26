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
    .dispatchPendingSave = dispatchPendingSave,
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
        if (self._persistence_state.tryStartKgc(.immediate) != .started) return Snapshot.Error.SaveAlreadyInProgress;
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
    const started = try self.startBackgroundSave(storages, origin, false);
    return if (started) .started else .scheduled;
}

pub fn dispatchPendingSave(ptr: *anyopaque, storages: []const Storage) anyerror!bool {
    const self: *KgcBackend = @ptrCast(@alignCast(ptr));

    return self.startBackgroundSave(storages, .manual, true);
}

fn startBackgroundSave(self: *KgcBackend, storages: []const Storage, origin: Store.TriggerOrigin, pending: bool) anyerror!bool {
    {
        var state_tx = try self._persistence_state.begin();
        defer state_tx.end();

        if (pending) {
            if (!self._persistence_state.claimPendingKgc()) return false;
        } else {
            const policy: PersistenceState.StartPolicy = if (origin == .manual) .schedule else .immediate;

            switch (self._persistence_state.tryStartKgc(policy)) {
                .started => {},
                .scheduled => return false,
                .busy => return Snapshot.Error.SaveAlreadyInProgress,
            }
        }
    }

    // NOTE: the placement is important. This way A busy return would not run finishKgc() and clear another operation’s active state
    errdefer {
        var tx = self._persistence_state.beginUncancelable();
        defer tx.end();
        if (pending) {
            self._persistence_state.failPendingKgcStart() catch |err| {
                self._logger.err("kgc: failed to release pending save claim", err, @errorReturnTrace());
            };
        } else self._persistence_state.finishKgc();
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
    const registration_error: ?PersistenceState.PendingStartError = blk: {
        var state_tx = self._persistence_state.beginUncancelable();
        defer state_tx.end();

        const child_save: PersistenceState.KgcBackgroundSave = .{
            .pid = pid,
            .captured_change_count = self._persistence_state.captureSnapshotChangeCount(),
            .origin = origin,
        };

        if (pending) {
            self._persistence_state.completePendingKgcStart(child_save) catch |err| break :blk err;
        } else self._persistence_state.setInFlightKgcSave(child_save);
        break :blk null;
    };

    if (registration_error) |err| {
        self._logger.err("kgc: failed to register pending save child", err, @errorReturnTrace());
        PersistenceState.terminateAndReapChild(pid);
        return err;
    }

    return true;
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
