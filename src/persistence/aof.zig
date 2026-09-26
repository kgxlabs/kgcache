const std = @import("std");
const Journal = @import("./journal_interface.zig");
const AofEncoder = @import("../codec/aof_encoder.zig");
const Manifest = @import("../persistence/manifest.zig");
const Storage = @import("../storage/interface.zig");
const object = @import("../object.zig");
const PersistenceState = @import("../persistence_state.zig");
const Store = @import("../store/interface.zig");
const Config = @import("../config.zig");
const time = @import("../time.zig");
const Lock = @import("../lock.zig");
const logging = @import("../logger.zig");

const AofBackend = @This();
const rewrite_retry_delay_ms: time.UnixMs = 60_000;

_lock: Lock,
_io: std.Io,
_allocator: std.mem.Allocator,
_encoder: AofEncoder,
_persistence_state: *PersistenceState,
_config: Config,
_logger: logging.Logger = logging.NoopLogger.logger(),
//NOTE: base file is only for parent process. never use it in child fork
// Live incr file handle, will keep the file handle for the lifetime of the process (we can because we open it in append mode)
_file: ?std.Io.File,
// incr_bytes is pure information and accounting state only. we will use file_offset whenever we need to append with seek
// They diverge only when we have multiple incr files (new incr file opening before child process fork).
// After successful rewrite, they become equal again.
// Total bytes across all incr files named by the live manifest.
_incr_bytes: u64,
// Current length of the live incr file, used as the next write offset.
_file_offset: u64,
_incr_seq: u32,
//NOTE: base file is only for child rewrite. never use it in parent
_base_file: ?std.Io.File = null,
_base_file_offset: u64 = 0,
_base_buffer: std.ArrayList(u8) = .empty,
_base_encoder: ?AofEncoder = null,
_base_size: u64,
_pending_base_seq: ?u32 = null,
_last_rewrite_attempt_ms: ?time.UnixMs = null,
// Last successful everysec fsync; null means the next flush must sync.
_last_fsync_ms: ?time.UnixMs = null,
_last_write_failed: bool = false,
_fork: *const fn () anyerror!std.posix.pid_t = forkProcess,
_loading: bool = false,
_buffer: std.ArrayList(u8) = .empty,

const vtable: Journal.VTable = .{
    .bgRewrite = bgRewrite,
    .dispatchPendingRewrite = dispatchPendingRewrite,
    .deinit = deinit,
    .finishRewrite = finishRewrite,
    .flush = flush,
    .prepareRecord = prepareRecord,
    .dueForRewrite = dueForRewrite,
    .beginLoading = beginLoading,
    .endLoading = endLoading,
    .reconcile = reconcile,
};

const PreparedRecord = struct {
    backend: *AofBackend,
    bytes: []const u8,
    db_index: u32,
};

pub fn journal(self: *AofBackend) Journal {
    return .{
        .ptr = self,
        .vtable = &vtable,
        ._lock = &self._lock,
    };
}

pub fn finishLoading(self: *AofBackend, base_size: u64, incr_bytes: u64, file_offset: u64) void {
    self._base_size = base_size;
    self._incr_bytes = incr_bytes;
    self._file_offset = file_offset;
    self._encoder.resetDbTracking();
}

// TODO: Refactor init. separate concerns
pub fn init(io: std.Io, allocator: std.mem.Allocator, state: *PersistenceState, config: Config) !AofBackend {
    const cwd = std.Io.Dir.cwd();

    cwd.createDir(io, config.append_dirname, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const dir = try cwd.openDir(io, config.append_dirname, .{});
    defer dir.close(io);

    var incr_seq: u32 = 1;
    var base_size: u64 = 0;
    var incr_bytes: u64 = 0;
    const read_manifest_name = try Manifest.manifestName(allocator, config.append_filename);
    defer allocator.free(read_manifest_name);

    const maybe_manifest = try Manifest.read(
        io,
        allocator,
        dir,
        read_manifest_name,
    );

    // if manifest exists (reopening), set live seq of incr
    if (maybe_manifest) |manifest| {
        defer manifest.deinit(allocator);
        const maybe_live_incr = Manifest.liveIncr(manifest);
        if (maybe_live_incr) |live_incr| {
            incr_seq = live_incr.seq;
        } else {
            incr_seq = Manifest.nextSeq(manifest);
        }

        for (manifest.incrs) |incr| {
            const incr_file = try dir.openFile(io, incr.name, .{});
            defer incr_file.close(io);
            incr_bytes += try incr_file.length(io);
        }

        if (manifest.base) |base_entry| {
            const base_file = try dir.openFile(io, base_entry.name, .{});
            defer base_file.close(io);
            base_size = try base_file.length(io);
        }
    } else {
        // if there are no manifest yet, create one and write a live incr
        const incr_name = try Manifest.incrName(allocator, config.append_filename, incr_seq);
        defer allocator.free(incr_name);

        const incr: Manifest.Entry = .{
            .kind = .incr,
            .seq = incr_seq,
            .name = incr_name,
        };
        var incrs = [_]Manifest.Entry{incr};
        const write_manifest_name = try Manifest.manifestName(allocator, config.append_filename);
        defer allocator.free(write_manifest_name);

        try Manifest.write(
            io,
            allocator,
            dir,
            write_manifest_name,
            .{ .base = null, .incrs = &incrs },
        );
    }

    const incr_name = try Manifest.incrName(allocator, config.append_filename, incr_seq);
    defer allocator.free(incr_name);

    const file = dir.openFile(io, incr_name, .{ .mode = .read_write }) catch |err| switch (err) {
        error.FileNotFound => try dir.createFile(io, incr_name, .{}),
        else => return err,
    };
    errdefer file.close(io);

    const file_offset = try file.length(io);

    return .{
        ._lock = Lock.init(io),
        ._io = io,
        ._allocator = allocator,
        ._encoder = AofEncoder.init(),
        ._persistence_state = state,
        ._config = config,
        ._incr_seq = incr_seq,
        ._file = file,
        ._incr_bytes = incr_bytes,
        ._file_offset = file_offset,
        ._base_size = base_size,
    };
}

pub fn prepareRecord(ptr: *anyopaque, event: Journal.WriteEvent) anyerror!Journal.Record {
    const self: *AofBackend = @ptrCast(@alignCast(ptr));

    if (self._loading) return Journal.Record.init(ptr, event, ignoreWrite, ignoreAbort);

    if (self._last_write_failed) return Journal.Error.JournalWriteBlocked;

    const prepared = try self._allocator.create(PreparedRecord);
    errdefer self._allocator.destroy(prepared);

    const encoded = try self._encoder.encodeWriteEvent(self._allocator, event);
    errdefer self._encoder.deinit(self._allocator, encoded.bytes);

    try self._buffer.ensureUnusedCapacity(self._allocator, encoded.bytes.len);

    prepared.* = .{
        .backend = self,
        .bytes = encoded.bytes,
        .db_index = encoded.db_index,
    };

    return Journal.Record.init(prepared, event, publishPreparedRecord, abortPreparedRecord);
}

pub fn bgRewrite(ptr: *anyopaque, storages: []const Storage, origin: Store.TriggerOrigin) anyerror!PersistenceState.BackgroundStartOutcome {
    const self: *AofBackend = @ptrCast(@alignCast(ptr));
    const started = try self.startBackgroundRewrite(storages, origin, false);
    return if (started) .started else .scheduled;
}

pub fn dispatchPendingRewrite(ptr: *anyopaque, storages: []const Storage) anyerror!bool {
    const self: *AofBackend = @ptrCast(@alignCast(ptr));
    return self.startBackgroundRewrite(storages, .manual, true);
}

fn startBackgroundRewrite(self: *AofBackend, storages: []const Storage, origin: Store.TriggerOrigin, pending: bool) anyerror!bool {
    {
        var state_tx = try self._persistence_state.begin();
        defer state_tx.end();
        if (pending) {
            if (!self._persistence_state.claimPendingAof()) return false;
        } else {
            const policy: PersistenceState.StartPolicy = if (origin == .manual) .schedule else .immediate;
            switch (self._persistence_state.tryStartAof(policy)) {
                .started => {},
                .scheduled => return false,
                .busy => return error.RewriteAlreadyInProgress,
            }
        }
    }

    self._last_rewrite_attempt_ms = time.nowMs(self._io);
    var child_started = false;

    errdefer {
        if (!child_started) {
            var state_tx = self._persistence_state.beginUncancelable();
            if (pending) {
                self._persistence_state.failPendingAofStart() catch |err| {
                    self._logger.err("aof: failed to release pending rewrite claim", err, @errorReturnTrace());
                };
            } else self._persistence_state.finishAof();
            state_tx.end();
        }
    }

    try flushLocked(self, time.nowMs(self._io));

    const cwd = std.Io.Dir.cwd();
    cwd.createDir(self._io, self._config.append_dirname, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // read existing manifest
    const manifest_name = try Manifest.manifestName(self._allocator, self._config.append_filename);
    defer self._allocator.free(manifest_name);
    const dir = try cwd.openDir(self._io, self._config.append_dirname, .{});
    defer dir.close(self._io);

    const maybe_manifest = try Manifest.read(
        self._io,
        self._allocator,
        dir,
        manifest_name,
    );

    if (maybe_manifest == null) {
        return Journal.Error.MissingAofManifest;
    }
    const manifest = maybe_manifest.?;
    defer manifest.deinit(self._allocator);

    const base_seq = Manifest.nextSeq(manifest);
    const new_incr_seq = base_seq + 1;
    const new_incr_name = try Manifest.incrName(
        self._allocator,
        self._config.append_filename,
        new_incr_seq,
    );
    defer self._allocator.free(new_incr_name);

    const new_incr_file = dir.openFile(self._io, new_incr_name, .{ .mode = .read_write }) catch |err| switch (err) {
        error.FileNotFound => try dir.createFile(self._io, new_incr_name, .{}),
        else => return err,
    };
    var new_incr_owned = true;
    errdefer if (new_incr_owned) new_incr_file.close(self._io);

    // add new incr file to the list by allocating memory
    const updated_incrs = try self._allocator.alloc(Manifest.Entry, manifest.incrs.len + 1);
    defer self._allocator.free(updated_incrs);

    std.mem.copyForwards(Manifest.Entry, updated_incrs[0..manifest.incrs.len], manifest.incrs);
    updated_incrs[manifest.incrs.len] = .{
        .name = new_incr_name,
        .seq = new_incr_seq,
        .kind = .incr,
    };
    try Manifest.write(
        self._io,
        self._allocator,
        dir,
        manifest_name,
        .{ .base = manifest.base, .incrs = updated_incrs },
    );
    // Startup reconciliation deletes generated files absent from the manifest,
    // so the new incremental must be published before any writes can reach it.

    // switch file handle and reset db so that we can start from scratch for new incr file
    const old_file = self._file;
    self._file = new_incr_file;
    new_incr_owned = false;
    self._incr_seq = new_incr_seq;
    self._file_offset = 0;
    self._encoder.resetDbTracking();
    if (old_file) |file| file.close(self._io);

    // start the fork
    const pid = try self._fork();

    if (pid == 0) {
        // The child inherits stdin, stdout, and stderr from the parent.
        // It needs no stdin. Close stdout so tests waiting for output can finish.
        // Keep stderr open to report child errors.
        _ = std.c.close(std.posix.STDIN_FILENO);
        _ = std.c.close(std.posix.STDOUT_FILENO);

        self.writeBase(storages, base_seq) catch |err| {
            // TODO: Send the source error to the parent through a pipe so the
            // child does not lock logger state copied during fork.
            self._logger.err("aof: background rewrite failed", err, @errorReturnTrace());
            std.c._exit(1);
        };

        // never reutrn . do not fall back into caller's connection loop since this is a child process now
        // using _exit to sidestep clearing the buffered data (at the time of fork) completely
        std.c._exit(0);
    }

    const previous_pending_base_seq = self._pending_base_seq;
    self._pending_base_seq = base_seq;

    // Fork succeeded, so cancellation must not leave the child untracked.
    const registration_error: ?PersistenceState.PendingStartError = blk: {
        var state_tx = self._persistence_state.beginUncancelable();
        defer state_tx.end();

        const rewrite: PersistenceState.AofBackgroundRewrite = .{
            .pid = pid,
            .base_seq = base_seq,
            .origin = origin,
        };

        if (pending) {
            self._persistence_state.completePendingAofStart(rewrite) catch |err| break :blk err;
        } else self._persistence_state.setInFlightAofRewrite(rewrite);

        break :blk null;
    };

    if (registration_error) |err| {
        self._logger.err("aof: failed to register pending rewrite child", err, @errorReturnTrace());

        PersistenceState.terminateAndReapChild(pid);
        self._pending_base_seq = previous_pending_base_seq;

        return err;
    }

    child_started = true;

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

pub fn dueForRewrite(ptr: *anyopaque, config: Config) anyerror!bool {
    const self: *AofBackend = @ptrCast(@alignCast(ptr));

    if (!config.append_only or config.auto_aof_rewrite_percentage == 0) return false;
    {
        var state_tx = try self._persistence_state.begin();
        defer state_tx.end();
        if (self._persistence_state.aofInProgress()) return false;
    }

    if (self._last_rewrite_attempt_ms) |last_attempt_ms| {
        const now_ms = time.nowMs(self._io);
        // NOTE: normally now_ms is always greater than the last attempt ms
        // now_ms < last_attempt_ms is to protect against NTP correction, manual clock adjustment, VM time changes, or suspend/resume behavio
        if (now_ms < last_attempt_ms or now_ms - last_attempt_ms < rewrite_retry_delay_ms) {
            return false;
        }
    }

    const current_size: u128 = @as(u128, self._base_size) + self._incr_bytes;
    if (current_size < config.auto_aof_rewrite_min_size) return false;

    // Before the first rewrite there is no base file, so growth has no
    // meaningful denominator and the minimum size becomes the only guard.
    if (self._base_size == 0) return true;

    const growth_percentage = @as(u128, self._incr_bytes) * 100 / self._base_size;
    return growth_percentage >= config.auto_aof_rewrite_percentage;
}

const BaseEntryVisitor = struct {
    backend: *AofBackend,
    db_index: u32,
};

// TODO: we are doing command based `base rewrite`for simplicity sake.
// For faster load time, Refactor to .kgc dump rewrite.
fn writeBase(self: *AofBackend, storages: []const Storage, base_seq: u32) !void {
    try self.beginBase(base_seq);

    for (storages, 0..) |storage, db_index| {
        if (storage.size() == 0) continue;

        var visitor: BaseEntryVisitor = .{
            .backend = self,
            .db_index = @intCast(db_index),
        };
        try storage.forEach(&visitor, visitBaseEntry);
    }

    try self.endBase();
}

fn beginBase(self: *AofBackend, seq: u32) !void {
    if (self._base_file != null) {
        return Journal.Error.BaseAlreadyOpen;
    }

    const base_name = try Manifest.baseName(
        self._allocator,
        self._config.append_filename,
        seq,
    );
    defer self._allocator.free(base_name);

    const cwd = std.Io.Dir.cwd();
    const dir = try cwd.openDir(
        self._io,
        self._config.append_dirname,
        .{},
    );
    defer dir.close(self._io);

    // createFile will truncates an existing file with the same name.
    // This is intentional to clean up any previous failed rewrite
    const base_file = try dir.createFile(
        self._io,
        base_name,
        .{},
    );
    errdefer base_file.close(self._io);

    // NOTE: This is to make sure the following things
    // 1. This will avoid wasting file descriptor
    // 2. OS wont fully release the file descriptor if something is still using it.
    //    in our case both parent and child can hold a file descriptor. if we do not close it for child here, it wont be fully released by OS
    //    even when parent close it unless we close it for child (in reaping mechanism) as well
    //  3. closing now will prevent accidental rewrite. child must only write to base_file and never _file
    if (self._file) |incr_file| {
        incr_file.close(self._io);
        self._file = null;
    }

    self._base_file = base_file;
    self._base_file_offset = 0;
    self._base_encoder = AofEncoder.init();
}

fn visitBaseEntry(ctx: *anyopaque, key: []const u8, value: object.Object, exp: ?time.UnixMs) anyerror!void {
    const visitor: *BaseEntryVisitor = @ptrCast(@alignCast(ctx));
    try visitor.backend.writeBaseEntry(visitor.db_index, key, value, exp);
}

fn writeBaseEntry(self: *AofBackend, db_index: u32, key: []const u8, value: object.Object, exp: ?time.UnixMs) !void {
    const encoder = if (self._base_encoder) |*base_encoder|
        base_encoder
    else
        return Journal.Error.BaseEncoderMissing;

    const encoded = try encoder.encodeRewriteEntry(self._allocator, .{
        .db_index = db_index,
        .key = key,
        .value = value,
        .expires_at = exp,
    });
    defer encoder.deinit(self._allocator, encoded.bytes);

    try self._base_buffer.appendSlice(self._allocator, encoded.bytes);
    encoder.commitDb(encoded.db_index);
}

// TODO: Refactor this and flushLocked. some of the logics are duplciated
fn endBase(self: *AofBackend) !void {
    const file = self._base_file orelse return Journal.Error.BaseFileMissing;
    var write_buf: [1024]u8 = undefined;
    var file_writer = file.writer(self._io, &write_buf);

    try file_writer.seekTo(self._base_file_offset);
    try file_writer.interface.writeAll(self._base_buffer.items);
    try file_writer.interface.flush();

    try file.sync(self._io);

    file.close(self._io);
    self._base_file = null;
    self._base_file_offset = 0;
    self._base_buffer.clearRetainingCapacity();
    self._base_encoder = null;
}

pub fn finishRewrite(ptr: *anyopaque, reap_result: PersistenceState.ReapResult) anyerror!void {
    const self: *AofBackend = @ptrCast(@alignCast(ptr));
    if (reap_result == .running) return Journal.Error.RewriteStillRunning;

    const base_seq = self._pending_base_seq orelse return Journal.Error.MissingPendingBase;
    defer self._pending_base_seq = null;

    const cwd = std.Io.Dir.cwd();
    const dir = try cwd.openDir(
        self._io,
        self._config.append_dirname,
        .{},
    );
    defer dir.close(self._io);

    const base_name = try Manifest.baseName(
        self._allocator,
        self._config.append_filename,
        base_seq,
    );
    defer self._allocator.free(base_name);

    if (reap_result == .failed) {
        self._last_rewrite_attempt_ms = time.nowMs(self._io);
        dir.deleteFile(self._io, base_name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        return;
    }

    const manifest_name = try Manifest.manifestName(
        self._allocator,
        self._config.append_filename,
    );
    defer self._allocator.free(manifest_name);

    const maybe_manifest = try Manifest.read(
        self._io,
        self._allocator,
        dir,
        manifest_name,
    );
    const manifest = maybe_manifest orelse
        return Journal.Error.MissingAofManifest;
    defer manifest.deinit(self._allocator);

    const live_incr = Manifest.liveIncr(manifest) orelse
        return Journal.Error.MissingLiveAofFile;

    if (live_incr.seq != self._incr_seq or live_incr.seq != base_seq + 1) {
        return Journal.Error.InvalidManifestSequence;
    }

    const base_file = try dir.openFile(
        self._io,
        base_name,
        .{},
    );
    defer base_file.close(self._io);

    // A command-based base can legitimately be empty when there are no live
    // entries, so existence and readable metadata are the sanity checks.
    const base_size = try base_file.length(self._io);

    const live_file = self._file orelse return Journal.Error.MissingLiveAofFile;
    const live_incr_size = try live_file.length(self._io);

    const new_base: Manifest.Entry = .{
        .name = base_name,
        .seq = base_seq,
        .kind = .base,
    };
    var new_incrs = [_]Manifest.Entry{live_incr};

    try Manifest.write(
        self._io,
        self._allocator,
        dir,
        manifest_name,
        .{ .base = new_base, .incrs = &new_incrs },
    );

    // delete old base and incrs files
    var delete_error: ?anyerror = null;
    if (manifest.base) |old_base| {
        dir.deleteFile(self._io, old_base.name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => if (delete_error == null) {
                delete_error = err;
            },
        };
    }
    for (manifest.incrs) |old_incr| {
        if (old_incr.seq == live_incr.seq) continue;
        dir.deleteFile(self._io, old_incr.name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => if (delete_error == null) {
                delete_error = err;
            },
        };
    }

    // reset base size and incr bytes to new base and live incr
    self._base_size = base_size;
    self._incr_bytes = live_incr_size;
    self._last_rewrite_attempt_ms = null;

    if (delete_error) |err| return err;
}

pub fn flush(ptr: *anyopaque, now_ms: i64, options: Journal.FlushOptions) anyerror!void {
    const self: *AofBackend = @ptrCast(@alignCast(ptr));
    if (options.mode == .if_required and self._config.append_fsync != .always) return;

    errdefer {
        self._last_write_failed = true;
    }

    try flushLocked(self, now_ms);
}

pub fn beginLoading(ptr: *anyopaque) void {
    const self: *AofBackend = @ptrCast(@alignCast(ptr));
    self._loading = true;
}

pub fn endLoading(ptr: *anyopaque) void {
    const self: *AofBackend = @ptrCast(@alignCast(ptr));
    self._loading = false;
}

pub fn reconcile(
    ptr: *anyopaque,
    io: std.Io,
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    filename: []const u8,
    manifest: ?Manifest.Manifest,
) anyerror!void {
    const self: *AofBackend = @ptrCast(@alignCast(ptr));
    const loaded_manifest = manifest orelse return Journal.Error.MissingAofManifest;

    const manifest_name = try Manifest.manifestName(allocator, filename);
    defer allocator.free(manifest_name);

    // Safe only because rewrite publishes a newly cut incremental before using
    // it; therefore every file containing live data is named by this manifest.
    var referenced = std.StringHashMap(void).init(allocator);
    defer referenced.deinit();

    if (loaded_manifest.base) |base| {
        try referenced.put(base.name, {});
    }
    for (loaded_manifest.incrs) |incr| {
        try referenced.put(incr.name, {});
    }

    var new_incr_name: ?[]u8 = null;
    defer if (new_incr_name) |name| allocator.free(name);

    // if there are no incrs file stated in manifest, we are going to create one because `bgrewriteaof` commander expects incr file to exist.
    // it will throw fatal error if incr is not there
    if (loaded_manifest.incrs.len == 0) {
        const incr_seq = Manifest.nextSeq(loaded_manifest);

        // The file opened during init must be the same incremental we are about
        // to publish otherwise the manifest would not describe future writes
        if (incr_seq != self._incr_seq) return Journal.Error.InvalidManifestSequence;

        const incr_name = try Manifest.incrName(allocator, filename, incr_seq);
        new_incr_name = incr_name;

        // reset existing file related things
        if (self._file) |file| file.close(io);
        self._file = null;
        self._file = try dir.createFile(io, incr_name, .{});
        self._file_offset = 0;
        self._incr_bytes = 0;
        self._encoder.resetDbTracking();

        try Manifest.write(
            io,
            allocator,
            dir,
            manifest_name,
            .{
                .base = loaded_manifest.base,
                .incrs = &[_]Manifest.Entry{.{
                    .name = incr_name,
                    .seq = incr_seq,
                    .kind = .incr,
                }},
            },
        );

        try referenced.put(incr_name, {});
    }

    const tmp_manifest_name = try std.fmt.allocPrint(
        allocator,
        "{s}.tmp",
        .{manifest_name},
    );
    defer allocator.free(tmp_manifest_name);

    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        // NOTE: later if we have nested structure, this can change
        if (entry.kind != .file) continue;

        const is_stale_manifest = std.mem.eql(u8, entry.name, tmp_manifest_name);
        const is_orphan_data = isAofDataFilename(entry.name, filename) and
            !referenced.contains(entry.name);
        if (!is_stale_manifest and !is_orphan_data) continue;

        try dir.deleteFile(io, entry.name);
    }
}

// <append_filename>.<seq>.base => true
// <append_filename>.<seq>.incr => true
// everything else => false
fn isAofDataFilename(name: []const u8, append_filename: []const u8) bool {
    if (!std.mem.startsWith(u8, name, append_filename)) return false;

    const remainder = name[append_filename.len..];
    if (remainder.len == 0 or remainder[0] != '.') return false;

    const suffix = if (std.mem.endsWith(u8, remainder, ".base"))
        ".base"
    else if (std.mem.endsWith(u8, remainder, ".incr"))
        ".incr"
    else
        return false;

    // + 1 for "."
    if (remainder.len <= 1 + suffix.len) return false;

    const seq = remainder[1 .. remainder.len - suffix.len];
    if (seq.len == 0) return false;
    for (seq) |char| {
        if (!std.ascii.isDigit(char)) return false;
    }
    return true;
}

pub fn deinit(ptr: *anyopaque) anyerror!void {
    const self: *AofBackend = @ptrCast(@alignCast(ptr));
    const now_ms = time.nowMs(self._io);
    var close_error: ?anyerror = null;

    flush(ptr, now_ms, .{}) catch |err| {
        close_error = err;
    };

    if (self._file) |file| {
        if (close_error == null and self._config.append_fsync == .everysec) {
            file.sync(self._io) catch |err| {
                close_error = err;
            };
            if (close_error == null) self._last_fsync_ms = now_ms;
        }

        file.close(self._io);
        self._file = null;
    }

    self._buffer.deinit(self._allocator);
    if (close_error) |err| return err;
}

// TODO: this flush locked itself does not claim append lock but remind callers to claim it
// Naming is confusing. Improve it.
fn flushLocked(self: *AofBackend, now_ms: time.UnixMs) !void {
    const file = self._file orelse return Journal.Error.MissingLiveAofFile;
    var write_buf: [1024]u8 = undefined;
    var file_writer = file.writer(self._io, &write_buf);
    // NOTE: We need to go to the exact bytes because new fresh writer starts at pos 0.
    try file_writer.seekTo(self._file_offset);
    try file_writer.interface.writeAll(self._buffer.items);
    try file_writer.interface.flush();

    const should_fsync = switch (self._config.append_fsync) {
        .always => true,
        .everysec => if (self._last_fsync_ms) |last_fsync_ms|
            now_ms >= last_fsync_ms and now_ms - last_fsync_ms >= 1000
        else
            true,
        .no => false,
    };
    if (should_fsync) {
        try file.sync(self._io);
        self._last_fsync_ms = now_ms;
    }

    self._incr_bytes += self._buffer.items.len;
    self._file_offset += self._buffer.items.len;
    self._buffer.clearRetainingCapacity();
    self._last_write_failed = false;
}

fn publishPreparedRecord(ptr: *anyopaque, _: Journal.WriteEvent) void {
    const prepared: *PreparedRecord = @ptrCast(@alignCast(ptr));
    const self = prepared.backend;
    defer self._allocator.destroy(prepared);
    defer self._encoder.deinit(self._allocator, prepared.bytes);

    self._buffer.appendSliceAssumeCapacity(prepared.bytes);
    self._encoder.commitDb(prepared.db_index);
}

fn abortPreparedRecord(ptr: *anyopaque, _: Journal.WriteEvent) void {
    const prepared: *PreparedRecord = @ptrCast(@alignCast(ptr));
    const self = prepared.backend;

    self._encoder.deinit(self._allocator, prepared.bytes);
    self._allocator.destroy(prepared);
}

fn ignoreWrite(_: *anyopaque, _: Journal.WriteEvent) void {
    return;
}

fn ignoreAbort(_: *anyopaque, _: Journal.WriteEvent) void {
    return;
}

test "dueForRewrite backs off after a failed rewrite attempt" {
    try @import("aof_test_helpers.zig").withScratchDir("scratch-aof-rewrite-backoff", struct {
        fn run(io: std.Io, _: std.Io.Dir) !void {
            const testing = std.testing;
            var state = PersistenceState.init(io, .{ .mutual_exclusive = false });
            const config: Config = .{
                .append_only = true,
                .append_dirname = "scratch-aof-rewrite-backoff",
                .auto_aof_rewrite_min_size = 1,
            };

            var backend = try AofBackend.init(io, testing.allocator, &state, config);
            defer backend.journal().deinit() catch {};
            backend._base_size = 0;
            backend._incr_bytes = 1;
            backend._last_rewrite_attempt_ms = time.nowMs(io);

            const journal_handle = backend.journal();
            var tx = try journal_handle.begin();
            defer tx.end();
            try testing.expect(!(try journal_handle.dueForRewrite(config)));

            backend._last_rewrite_attempt_ms.? -= rewrite_retry_delay_ms;
            try testing.expect(try journal_handle.dueForRewrite(config));
        }
    }.run);
}

test "writeBaseEntry buffers reconstruction commands and commits the selected db" {
    try @import("aof_test_helpers.zig").withScratchDir("scratch-aof-write-base-entry", struct {
        fn run(io: std.Io, dir: std.Io.Dir) !void {
            _ = dir;
            const testing = std.testing;

            var state = PersistenceState.init(io, .{ .mutual_exclusive = false });
            const config: Config = .{ .append_dirname = "scratch-aof-write-base-entry" };

            var backend = try AofBackend.init(io, testing.allocator, &state, config);
            defer backend.journal().deinit() catch {};
            defer backend._base_buffer.deinit(testing.allocator);
            backend._base_encoder = AofEncoder.init();
            const journal_handle = backend.journal();
            var tx = try journal_handle.begin();
            defer tx.end();

            try backend.writeBaseEntry(3, "first", .{ .string = "one" }, null);
            try backend.writeBaseEntry(3, "second", .{ .string = "two" }, 456);

            const contents = backend._base_buffer.items;
            try testing.expectEqual(@as(usize, 1), std.mem.count(u8, contents, "SELECT"));
            try testing.expectEqual(@as(usize, 2), std.mem.count(u8, contents, "SET"));
            try testing.expect(std.mem.indexOf(u8, contents, "first") != null);
            try testing.expect(std.mem.indexOf(u8, contents, "second") != null);
            try testing.expect(std.mem.indexOf(u8, contents, "PXAT") != null);
            try testing.expect(std.mem.indexOf(u8, contents, "456") != null);
        }
    }.run);
}
