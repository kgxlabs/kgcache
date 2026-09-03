const std = @import("std");
const Journal = @import("./journal_interface.zig");
const AofEncoder = @import("../codec/aof_encoder.zig");
const Manifest = @import("../persistence/manifest.zig");
const Storage = @import("../storage/interface.zig");
const object = @import("../object.zig");
const PersistenceState = @import("../persistence_state.zig");
const Config = @import("../config.zig");
const time = @import("../time.zig");
const helpers = @import("../helpers.zig");

const AofBackend = @This();

_mutex: std.Io.Mutex = .init,
_io: std.Io,
_allocator: std.mem.Allocator,
_encoder: AofEncoder,
_persistence_state: *PersistenceState,
_config: Config,
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
_last_write_failed: bool = false,
_loading: bool = false,
_buffer: std.ArrayList(u8) = .empty,

const vtable: Journal.VTable = .{
    .bgRewrite = bgRewrite,
    .deinit = deinit,
    .finishRewrite = finishRewrite,
    .flush = flush,
    .onWrite = onWrite,
    .dueForRewrite = dueForRewrite,
    .beginLoading = beginLoading,
    .endLoading = endLoading,
    .reconcile = reconcile,
};

pub fn journal(self: *AofBackend) Journal {
    return .{
        .ptr = self,
        .vtable = &vtable,
    };
}

pub fn finishLoading(self: *AofBackend, base_size: u64, incr_bytes: u64, file_offset: u64) void {
    self._base_size = base_size;
    self._incr_bytes = incr_bytes;
    self._file_offset = file_offset;
    self._encoder.resetDbTracking();
}

// TODO: Refactor init. separate concerns
pub fn init(io: std.Io, allocator: std.mem.Allocator, state: *PersistenceState, config: Config) Journal.Error!AofBackend {
    const cwd = std.Io.Dir.cwd();

    cwd.createDir(io, config.append_dirname, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return Journal.Error.FailedToOpenDir,
    };

    const dir = cwd.openDir(io, config.append_dirname, .{}) catch return Journal.Error.FailedToOpenDir;
    defer dir.close(io);

    var incr_seq: u32 = 1;
    var base_size: u64 = 0;
    var incr_bytes: u64 = 0;
    const read_manifest_name = Manifest.manifestName(allocator, config.append_filename) catch return Journal.Error.FailedToReadManifest;
    defer allocator.free(read_manifest_name);

    const maybe_manifest = Manifest.read(
        io,
        allocator,
        dir,
        read_manifest_name,
    ) catch return Journal.Error.FailedToReadManifest;

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
            const incr_file = dir.openFile(io, incr.name, .{}) catch return Journal.Error.FailedToOpenIncrFile;
            defer incr_file.close(io);
            incr_bytes += incr_file.length(io) catch return Journal.Error.FailedToOpenIncrFile;
        }

        if (manifest.base) |base_entry| {
            const base_file = dir.openFile(io, base_entry.name, .{}) catch return Journal.Error.FailedToOpenBase;
            defer base_file.close(io);
            base_size = base_file.length(io) catch return Journal.Error.FailedToOpenBase;
        }
    } else {
        // if there are no manifest yet, create one and write a live incr
        const incr_name = Manifest.incrName(allocator, config.append_filename, incr_seq) catch return Journal.Error.FailedToWriteManifest;
        defer allocator.free(incr_name);

        const incr: Manifest.Entry = .{
            .kind = .incr,
            .seq = incr_seq,
            .name = incr_name,
        };
        var incrs = [_]Manifest.Entry{incr};
        const write_manifest_name = Manifest.manifestName(allocator, config.append_filename) catch return Journal.Error.FailedToWriteManifest;
        defer allocator.free(write_manifest_name);

        Manifest.write(
            io,
            allocator,
            dir,
            write_manifest_name,
            .{ .base = null, .incrs = &incrs },
        ) catch return Journal.Error.FailedToWriteManifest;
    }

    const incr_name = Manifest.incrName(allocator, config.append_filename, incr_seq) catch return Journal.Error.FailedToWriteManifest;
    defer allocator.free(incr_name);

    const file = dir.openFile(io, incr_name, .{ .mode = .read_write }) catch |err| switch (err) {
        error.FileNotFound => dir.createFile(io, incr_name, .{}) catch return Journal.Error.FailedToOpenIncrFile,
        else => return Journal.Error.FailedToOpenIncrFile,
    };

    const file_offset = file.length(io) catch return Journal.Error.FailedToOpenIncrFile;

    return .{
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

pub fn onWrite(ptr: *anyopaque, event: Journal.WriteEvent) Journal.Error!void {
    const self: *AofBackend = @ptrCast(@alignCast(ptr));

    if (self._loading) return;

    if (self._last_write_failed) return Journal.Error.UnableToRecordWrite;

    try appendEvent(self, event);
    if (self._config.append_fsync == .always) {
        try flush(ptr, time.nowMs(self._io));
    }
}

pub fn bgRewrite(ptr: *anyopaque, storages: []const Storage) Journal.Error!void {
    const self: *AofBackend = @ptrCast(@alignCast(ptr));
    errdefer |err| {
        self._last_write_failed = true;
        helpers.logStderr(self._io, "aof: failed to start rewrite: {s}\n", .{@errorName(err)});
    }

    if (!self._persistence_state.tryStartAof()) return error.RewriteAlreadyInProgress;
    self._last_rewrite_attempt_ms = time.nowMs(self._io);

    self._mutex.lockUncancelable(self._io);
    defer self._mutex.unlock(self._io);
    try flushLocked(self);

    const cwd = std.Io.Dir.cwd();
    cwd.createDir(self._io, self._config.append_dirname, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return error.FailedToOpenDir,
    };

    // read existing manifest
    const manifest_name = Manifest.manifestName(self._allocator, self._config.append_filename) catch return error.FailedToReadManifest;
    defer self._allocator.free(manifest_name);
    const dir = cwd.openDir(self._io, self._config.append_dirname, .{}) catch return error.FailedToOpenDir;
    defer dir.close(self._io);

    const maybe_manifest = Manifest.read(
        self._io,
        self._allocator,
        dir,
        manifest_name,
    ) catch return error.FailedToReadManifest;
    if (maybe_manifest == null) {
        helpers.logStdout(self._io, "aof: cannot find existing manifest file: {s}\n", .{@errorName(Journal.Error.FailedToRewriteAof)});
        return error.FailedToRewriteAof;
    }
    const manifest = maybe_manifest.?;
    defer manifest.deinit(self._allocator);

    const base_seq = Manifest.nextSeq(manifest);
    const new_incr_seq = base_seq + 1;
    const new_incr_name = Manifest.incrName(
        self._allocator,
        self._config.append_filename,
        new_incr_seq,
    ) catch return error.FailedToWriteIncrFile;
    defer self._allocator.free(new_incr_name);

    const new_incr_file = dir.openFile(self._io, new_incr_name, .{ .mode = .read_write }) catch |err| switch (err) {
        error.FileNotFound => dir.createFile(self._io, new_incr_name, .{}) catch return error.FailedToOpenIncrFile,
        else => return error.FailedToOpenIncrFile,
    };
    errdefer new_incr_file.close(self._io);

    // add new incr file to the list by allocating memory
    const updated_incrs = try self._allocator.alloc(Manifest.Entry, manifest.incrs.len + 1);
    defer self._allocator.free(updated_incrs);

    std.mem.copyForwards(Manifest.Entry, updated_incrs[0..manifest.incrs.len], manifest.incrs);
    updated_incrs[manifest.incrs.len] = .{
        .name = new_incr_name,
        .seq = new_incr_seq,
        .kind = .incr,
    };
    Manifest.write(
        self._io,
        self._allocator,
        dir,
        manifest_name,
        .{ .base = manifest.base, .incrs = updated_incrs },
    ) catch {
        helpers.logStderr(self._io, "aof: failed to rewrite manifest file: {s}\n", .{@errorName(Journal.Error.FailedToWriteManifest)});
        return error.FailedToWriteManifest;
    };
    // Startup reconciliation deletes generated files absent from the manifest,
    // so the new incremental must be published before any writes can reach it.

    // switch file handle and reset db so that we can start from scratch for new incr file
    const old_file = self._file;
    self._file = new_incr_file;
    self._incr_seq = new_incr_seq;
    self._file_offset = 0;
    self._encoder.resetDbTracking();
    if (old_file) |file| file.close(self._io);

    // start the fork
    const rc = std.posix.system.fork();
    const pid: std.posix.pid_t = switch (std.posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .AGAIN, .NOMEM => {
            self._persistence_state.finishAof();
            return error.FailedToRewriteAof;
        },
        else => {
            self._persistence_state.finishAof();
            return error.FailedToRewriteAof;
        },
    };

    if (pid == 0) {
        // A background child has no business holding the parent's stdin/stdout
        // open -- besides not needing them, keeping a duplicate fd around
        // delays the OS from ever delivering EOF on them to whatever the
        // parent's other end is (a terminal, a log pipe, or -- as seen under
        // `zig build test` -- the build system's own IPC channel), even
        // after the parent itself has moved on. stderr stays open since the
        // failure path below deliberately writes to it.
        _ = std.c.close(std.posix.STDIN_FILENO);
        _ = std.c.close(std.posix.STDOUT_FILENO);

        self.writeBase(storages, base_seq) catch |err| {
            helpers.logStderr(self._io, "aof: background rewrite failed: {s}\n", .{@errorName(err)});
            std.c._exit(1);
        };

        // never reutrn . do not fall back into caller's connection loop since this is a child process now
        // using _exit to sidestep clearing the buffered data (at the time of fork) completely
        std.c._exit(0);
    }

    self._pending_base_seq = base_seq;
    self._persistence_state.setAofPid(pid);
}

pub fn dueForRewrite(ptr: *anyopaque, config: Config) bool {
    _ = ptr;
    _ = config;
    return false;
}

const BaseEntryVisitor = struct {
    backend: *AofBackend,
    db_index: u32,
};

// TODO: we are doing command based `base rewrite`for simplicity sake.
// For faster load time, Refactor to .kgc dump rewrite.
fn writeBase(self: *AofBackend, storages: []const Storage, base_seq: u32) Journal.Error!void {
    try self.beginBase(base_seq);

    for (storages, 0..) |storage, db_index| {
        if (storage.size() == 0) continue;

        var visitor: BaseEntryVisitor = .{
            .backend = self,
            .db_index = @intCast(db_index),
        };
        storage.forEach(&visitor, visitBaseEntry) catch return Journal.Error.FailedToRewriteAof;
    }

    try self.endBase();
}

fn beginBase(self: *AofBackend, seq: u32) Journal.Error!void {
    if (self._base_file != null) {
        return Journal.Error.FailedToOpenBase;
    }

    const base_name = Manifest.baseName(
        self._allocator,
        self._config.append_filename,
        seq,
    ) catch return Journal.Error.OutOfMemory;
    defer self._allocator.free(base_name);

    const cwd = std.Io.Dir.cwd();
    const dir = cwd.openDir(
        self._io,
        self._config.append_dirname,
        .{},
    ) catch return Journal.Error.FailedToOpenDir;
    defer dir.close(self._io);

    // createFile will truncates an existing file with the same name.
    // This is intentional to clean up any previous failed rewrite
    const base_file = dir.createFile(
        self._io,
        base_name,
        .{},
    ) catch return Journal.Error.FailedToOpenBase;
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

fn writeBaseEntry(self: *AofBackend, db_index: u32, key: []const u8, value: object.Object, exp: ?time.UnixMs) Journal.Error!void {
    const encoder = if (self._base_encoder) |*base_encoder|
        base_encoder
    else
        return Journal.Error.FailedToRewriteAof;

    const encoded = encoder.encodeRewriteEntry(self._allocator, .{
        .db_index = db_index,
        .key = key,
        .value = value,
        .expires_at = exp,
    }) catch return Journal.Error.OutOfMemory;
    defer encoder.deinit(self._allocator, encoded.bytes);

    self._base_buffer.appendSlice(self._allocator, encoded.bytes) catch return Journal.Error.FailedBufferAppend;
    encoder.commitDb(encoded.db_index);
}

// TODO: Refactor this and flushLocked. some of the logics are duplciated
fn endBase(self: *AofBackend) Journal.Error!void {
    const file = self._base_file orelse return Journal.Error.FailedToRewriteAof;
    var write_buf: [1024]u8 = undefined;
    var file_writer = file.writer(self._io, &write_buf);

    file_writer.seekTo(self._base_file_offset) catch return Journal.Error.FailedToWriteIncrFile;
    file_writer.interface.writeAll(self._base_buffer.items) catch return Journal.Error.FailedToWriteIncrFile;
    file_writer.interface.flush() catch return Journal.Error.FailedToWriteIncrFile;

    file.sync(self._io) catch return Journal.Error.FailedToRewriteAof;

    file.close(self._io);
    self._base_file = null;
    self._base_file_offset = 0;
    self._base_buffer.clearRetainingCapacity();
    self._base_encoder = null;
}

pub fn finishRewrite(ptr: *anyopaque, reap_result: PersistenceState.ReapResult) Journal.Error!void {
    const self: *AofBackend = @ptrCast(@alignCast(ptr));
    if (reap_result == .running) return Journal.Error.FailedToRewriteAof;

    self._mutex.lockUncancelable(self._io);
    defer self._mutex.unlock(self._io);

    const base_seq = self._pending_base_seq orelse return Journal.Error.FailedToRewriteAof;
    defer self._pending_base_seq = null;

    const cwd = std.Io.Dir.cwd();
    const dir = cwd.openDir(
        self._io,
        self._config.append_dirname,
        .{},
    ) catch return Journal.Error.FailedToOpenDir;
    defer dir.close(self._io);

    const base_name = Manifest.baseName(
        self._allocator,
        self._config.append_filename,
        base_seq,
    ) catch return Journal.Error.OutOfMemory;
    defer self._allocator.free(base_name);

    if (reap_result == .failed) {
        self._last_rewrite_attempt_ms = time.nowMs(self._io);
        dir.deleteFile(self._io, base_name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return Journal.Error.FailedToRewriteAof,
        };
        helpers.logStderr(self._io, "aof: rewrite failed; keeping the cut manifest and live incremental file\n", .{});
        return;
    }

    const manifest_name = Manifest.manifestName(
        self._allocator,
        self._config.append_filename,
    ) catch return Journal.Error.OutOfMemory;
    defer self._allocator.free(manifest_name);

    const maybe_manifest = Manifest.read(
        self._io,
        self._allocator,
        dir,
        manifest_name,
    ) catch return Journal.Error.FailedToReadManifest;
    const manifest = maybe_manifest orelse
        return Journal.Error.FailedToReadManifest;
    defer manifest.deinit(self._allocator);

    const live_incr = Manifest.liveIncr(manifest) orelse
        return Journal.Error.FailedToRewriteAof;
    if (live_incr.seq != self._incr_seq or live_incr.seq != base_seq + 1) {
        return Journal.Error.FailedToRewriteAof;
    }

    const base_file = dir.openFile(
        self._io,
        base_name,
        .{},
    ) catch return Journal.Error.FailedToOpenBase;
    defer base_file.close(self._io);

    // A command-based base can legitimately be empty when there are no live
    // entries, so existence and readable metadata are the sanity checks.
    const base_size = base_file.length(self._io) catch
        return Journal.Error.FailedToOpenBase;

    const live_file = self._file orelse return Journal.Error.FailedToOpenIncrFile;
    const live_incr_size = live_file.length(self._io) catch
        return Journal.Error.FailedToOpenIncrFile;

    const new_base: Manifest.Entry = .{
        .name = base_name,
        .seq = base_seq,
        .kind = .base,
    };
    var new_incrs = [_]Manifest.Entry{live_incr};

    Manifest.write(
        self._io,
        self._allocator,
        dir,
        manifest_name,
        .{ .base = new_base, .incrs = &new_incrs },
    ) catch return Journal.Error.FailedToWriteManifest;

    // delete old base and incrs files
    var delete_failed = false;
    if (manifest.base) |old_base| {
        dir.deleteFile(self._io, old_base.name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => delete_failed = true,
        };
    }
    for (manifest.incrs) |old_incr| {
        if (old_incr.seq == live_incr.seq) continue;
        dir.deleteFile(self._io, old_incr.name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => delete_failed = true,
        };
    }

    // reset base size and incr bytes to new base and live incr
    self._base_size = base_size;
    self._incr_bytes = live_incr_size;
    self._last_rewrite_attempt_ms = null;

    if (delete_failed) return Journal.Error.FailedToRewriteAof;
}

pub fn flush(ptr: *anyopaque, _: i64) Journal.Error!void {
    const self: *AofBackend = @ptrCast(@alignCast(ptr));
    errdefer |err| {
        self._last_write_failed = true;
        helpers.logStderr(self._io, "aof: failed to flush: {s}\n", .{@errorName(err)});
    }

    self._mutex.lockUncancelable(self._io);
    defer self._mutex.unlock(self._io);
    try flushLocked(self);
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
) Journal.Error!void {
    const self: *AofBackend = @ptrCast(@alignCast(ptr));
    const loaded_manifest = manifest orelse return Journal.Error.FailedToReadManifest;

    const manifest_name = Manifest.manifestName(allocator, filename) catch
        return Journal.Error.OutOfMemory;
    defer allocator.free(manifest_name);

    // Safe only because rewrite publishes a newly cut incremental before using
    // it; therefore every file containing live data is named by this manifest.
    var referenced = std.StringHashMap(void).init(allocator);
    defer referenced.deinit();

    if (loaded_manifest.base) |base| {
        referenced.put(base.name, {}) catch return Journal.Error.OutOfMemory;
    }
    for (loaded_manifest.incrs) |incr| {
        referenced.put(incr.name, {}) catch return Journal.Error.OutOfMemory;
    }

    var new_incr_name: ?[]u8 = null;
    defer if (new_incr_name) |name| allocator.free(name);

    // if there are no incrs file stated in manifest, we are going to create one because `bgrewriteaof` commander expects incr file to exist.
    // it will throw fatal error if incr is not there
    if (loaded_manifest.incrs.len == 0) {
        const incr_seq = Manifest.nextSeq(loaded_manifest);

        // The file opened during init must be the same incremental we are about
        // to publish otherwise the manifest would not describe future writes
        if (incr_seq != self._incr_seq) return Journal.Error.FailedToReconcileAof;

        const incr_name = Manifest.incrName(allocator, filename, incr_seq) catch
            return Journal.Error.OutOfMemory;
        new_incr_name = incr_name;

        // reset existing file related things
        if (self._file) |file| file.close(io);
        self._file = null;
        self._file = dir.createFile(io, incr_name, .{}) catch
            return Journal.Error.FailedToReconcileAof;
        self._file_offset = 0;
        self._incr_bytes = 0;
        self._encoder.resetDbTracking();

        Manifest.write(
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
        ) catch return Journal.Error.FailedToWriteManifest;

        referenced.put(incr_name, {}) catch return Journal.Error.OutOfMemory;
    }

    const tmp_manifest_name = std.fmt.allocPrint(
        allocator,
        "{s}.tmp",
        .{manifest_name},
    ) catch return Journal.Error.OutOfMemory;
    defer allocator.free(tmp_manifest_name);

    var deleted_count: usize = 0;
    var iterator = dir.iterate();
    while (iterator.next(io) catch return Journal.Error.FailedToReconcileAof) |entry| {
        // NOTE: later if we have nested structure, this can change
        if (entry.kind != .file) continue;

        const is_stale_manifest = std.mem.eql(u8, entry.name, tmp_manifest_name);
        const is_orphan_data = isAofDataFilename(entry.name, filename) and
            !referenced.contains(entry.name);
        if (!is_stale_manifest and !is_orphan_data) continue;

        dir.deleteFile(io, entry.name) catch return Journal.Error.FailedToReconcileAof;
        deleted_count += 1;
    }

    if (deleted_count > 0) {
        helpers.logStderr(io, "aof: removed {d} unreferenced file(s)\n", .{deleted_count});
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

pub fn deinit(ptr: *anyopaque) Journal.Error!void {
    const self: *AofBackend = @ptrCast(@alignCast(ptr));
    // stderr instead of propagating since close is the last gate for aof
    flush(ptr, time.nowMs(self._io)) catch |err| {
        helpers.logStderr(self._io, "aof: failed to close: {s}\n", .{@errorName(err)});
    };

    const file = self._file orelse return Journal.Error.FailedToCloseAof;
    file.sync(self._io) catch return Journal.Error.FailedToCloseAof;
    file.close(self._io);
    self._file = null;

    self._buffer.deinit(self._allocator);
}

// TODO: this flush locked itself does not claim append lock but remind callers to claim it
// Naming is confusing. Improve it.
fn flushLocked(self: *AofBackend) Journal.Error!void {
    const file = self._file orelse return Journal.Error.FailedToWriteIncrFile;
    var write_buf: [1024]u8 = undefined;
    var file_writer = file.writer(self._io, &write_buf);
    // NOTE: We need to go to the exact bytes because new fresh writer starts at pos 0.
    file_writer.seekTo(self._file_offset) catch return Journal.Error.FailedToWriteIncrFile;
    file_writer.interface.writeAll(self._buffer.items) catch return Journal.Error.FailedToWriteIncrFile;
    file_writer.interface.flush() catch return Journal.Error.FailedToWriteIncrFile;

    if (self._config.append_fsync == .always) {
        file.sync(self._io) catch return Journal.Error.FailedToWriteIncrFile;
    }

    self._incr_bytes += self._buffer.items.len;
    self._file_offset += self._buffer.items.len;
    self._buffer.clearRetainingCapacity();
    self._last_write_failed = false;
}

fn appendEvent(self: *AofBackend, event: Journal.WriteEvent) Journal.Error!void {
    self._mutex.lockUncancelable(self._io);
    defer self._mutex.unlock(self._io);

    const encoded = self._encoder.encodeWriteEvent(self._allocator, event) catch return Journal.Error.OutOfMemory;
    defer self._encoder.deinit(self._allocator, encoded.bytes);

    self._buffer.appendSlice(self._allocator, encoded.bytes) catch return Journal.Error.FailedBufferAppend;
    // we need to make sure that we only set db after we actaully successfully add the bytes to buffer
    self._encoder.commitDb(encoded.db_index);
}

fn sampleEvent() Journal.WriteEvent {
    return .{ .put = .{
        .db_index = 0,
        .key = "foo",
        .value = .{ .string = "bar" },
        .expires_at = null,
    } };
}

fn withScratchDir(comptime name: []const u8, comptime testFn: fn (std.Io, std.Io.Dir) anyerror!void) !void {
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    cwd.deleteTree(io, name) catch {};
    defer cwd.deleteTree(io, name) catch {};

    try cwd.createDir(io, name, .default_dir);
    var dir = try cwd.openDir(io, name, .{ .iterate = true });
    defer dir.close(io);

    try testFn(io, dir);
}

const TestStderrGuard = struct {
    saved: std.posix.fd_t,
    devnull: std.posix.fd_t,

    fn silence() !TestStderrGuard {
        const devnull = std.c.open("/dev/null", .{ .ACCMODE = .WRONLY });
        if (devnull < 0) return error.OpenDevNullFailed;
        errdefer _ = std.c.close(devnull);

        const saved = std.c.dup(std.posix.STDERR_FILENO);
        if (saved < 0) return error.DupFailed;
        errdefer _ = std.c.close(saved);

        if (std.c.dup2(devnull, std.posix.STDERR_FILENO) < 0) return error.DupFailed;
        return .{ .saved = saved, .devnull = devnull };
    }

    fn restore(self: TestStderrGuard) void {
        _ = std.c.dup2(self.saved, std.posix.STDERR_FILENO);
        _ = std.c.close(self.saved);
        _ = std.c.close(self.devnull);
    }
};

test "init creates the append directory and a seq-1 manifest on first boot" {
    try withScratchDir("scratch-aof-init-first-boot", struct {
        fn run(io: std.Io, dir: std.Io.Dir) !void {
            const testing = std.testing;

            var state = PersistenceState.init(io, false);
            const config: Config = .{ .append_dirname = "scratch-aof-init-first-boot" };

            var backend = try AofBackend.init(io, testing.allocator, &state, config);
            defer backend.journal().deinit() catch {};

            try testing.expectEqual(1, backend._incr_seq);
            try testing.expectEqual(0, backend._base_size);
            try testing.expectEqual(0, backend._incr_bytes);
            try testing.expectEqual(0, backend._file_offset);

            const manifest = try Manifest.read(io, testing.allocator, dir, "appendonly.aof.manifest") orelse return error.TestUnexpectedResult;
            defer manifest.deinit(testing.allocator);

            try testing.expect(manifest.base == null);
            try testing.expectEqual(1, manifest.incrs.len);
            try testing.expectEqual(1, manifest.incrs[0].seq);
            try testing.expectEqualStrings("appendonly.aof.1.incr", manifest.incrs[0].name);
        }
    }.run);
}

test "onWrite followed by flush puts the encoded command in the incr file" {
    try withScratchDir("scratch-aof-onwrite-flush", struct {
        fn run(io: std.Io, dir: std.Io.Dir) !void {
            const testing = std.testing;

            var state = PersistenceState.init(io, false);
            const config: Config = .{ .append_dirname = "scratch-aof-onwrite-flush" };

            var backend = try AofBackend.init(io, testing.allocator, &state, config);
            defer backend.journal().deinit() catch {};
            const j = backend.journal();

            try j.onWrite(sampleEvent());
            try j.flush(0);

            const contents = try dir.readFileAlloc(io, "appendonly.aof.1.incr", testing.allocator, .unlimited);
            defer testing.allocator.free(contents);

            try testing.expect(std.mem.indexOf(u8, contents, "SET") != null);
            try testing.expect(std.mem.indexOf(u8, contents, "foo") != null);
            try testing.expect(std.mem.indexOf(u8, contents, "bar") != null);
        }
    }.run);
}

test "onWrite alone leaves the file untouched" {
    try withScratchDir("scratch-aof-onwrite-buffers", struct {
        fn run(io: std.Io, dir: std.Io.Dir) !void {
            const testing = std.testing;

            var state = PersistenceState.init(io, false);
            const config: Config = .{ .append_dirname = "scratch-aof-onwrite-buffers" };

            var backend = try AofBackend.init(io, testing.allocator, &state, config);
            defer backend.journal().deinit() catch {};

            try backend.journal().onWrite(sampleEvent());

            const file = try dir.openFile(io, "appendonly.aof.1.incr", .{});
            defer file.close(io);
            try testing.expectEqual(0, try file.length(io));
        }
    }.run);
}

test "writeBaseEntry buffers reconstruction commands and commits the selected db" {
    try withScratchDir("scratch-aof-write-base-entry", struct {
        fn run(io: std.Io, dir: std.Io.Dir) !void {
            _ = dir;
            const testing = std.testing;

            var state = PersistenceState.init(io, false);
            const config: Config = .{ .append_dirname = "scratch-aof-write-base-entry" };

            var backend = try AofBackend.init(io, testing.allocator, &state, config);
            defer backend.journal().deinit() catch {};
            defer backend._base_buffer.deinit(testing.allocator);
            backend._base_encoder = AofEncoder.init();

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

test "init reopens the existing live incr file and appends after its existing contents rather than truncating it" {
    try withScratchDir("scratch-aof-reopen-no-truncate", struct {
        fn run(io: std.Io, dir: std.Io.Dir) !void {
            const testing = std.testing;
            const config: Config = .{ .append_dirname = "scratch-aof-reopen-no-truncate" };

            {
                var state = PersistenceState.init(io, false);
                var backend = try AofBackend.init(io, testing.allocator, &state, config);
                try backend.journal().onWrite(sampleEvent());
                try backend.journal().flush(0);
                try backend.journal().deinit();
            }

            const before = try dir.readFileAlloc(io, "appendonly.aof.1.incr", testing.allocator, .unlimited);
            defer testing.allocator.free(before);
            try testing.expect(before.len > 0);

            var state2 = PersistenceState.init(io, false);
            var backend2 = try AofBackend.init(io, testing.allocator, &state2, config);
            defer backend2.journal().deinit() catch {};

            try testing.expectEqual(before.len, backend2._incr_bytes);
            try testing.expectEqual(before.len, backend2._file_offset);

            try backend2.journal().onWrite(sampleEvent());
            try backend2.journal().flush(0);

            const after = try dir.readFileAlloc(io, "appendonly.aof.1.incr", testing.allocator, .unlimited);
            defer testing.allocator.free(after);

            try testing.expect(after.len > before.len);
            try testing.expect(std.mem.startsWith(u8, after, before));
        }
    }.run);
}

test "init picks the highest-seq incr from a manifest with several" {
    try withScratchDir("scratch-aof-picks-highest-seq", struct {
        fn run(io: std.Io, dir: std.Io.Dir) !void {
            const testing = std.testing;

            var incrs = [_]Manifest.Entry{
                .{ .name = "appendonly.aof.1.incr", .seq = 1, .kind = .incr },
                .{ .name = "appendonly.aof.2.incr", .seq = 2, .kind = .incr },
                .{ .name = "appendonly.aof.3.incr", .seq = 3, .kind = .incr },
            };
            try Manifest.write(io, testing.allocator, dir, "appendonly.aof.manifest", .{ .base = null, .incrs = &incrs });
            try dir.writeFile(io, .{ .sub_path = "appendonly.aof.1.incr", .data = "old" });
            try dir.writeFile(io, .{ .sub_path = "appendonly.aof.2.incr", .data = "older" });
            try dir.writeFile(io, .{ .sub_path = "appendonly.aof.3.incr", .data = "existing" });

            var state = PersistenceState.init(io, false);
            const config: Config = .{ .append_dirname = "scratch-aof-picks-highest-seq" };

            var backend = try AofBackend.init(io, testing.allocator, &state, config);
            defer backend.journal().deinit() catch {};

            try testing.expectEqual(3, backend._incr_seq);
            try testing.expectEqual(16, backend._incr_bytes);
            try testing.expectEqual(8, backend._file_offset);
        }
    }.run);
}

test "rewrite cut preserves total incr bytes and resets the live file offset" {
    try withScratchDir("scratch-aof-rewrite-cut-byte-accounting", struct {
        fn run(io: std.Io, dir: std.Io.Dir) !void {
            const testing = std.testing;
            var state = PersistenceState.init(io, false);
            const config: Config = .{ .append_dirname = "scratch-aof-rewrite-cut-byte-accounting" };

            var backend = try AofBackend.init(io, testing.allocator, &state, config);
            defer backend.journal().deinit() catch {};

            try backend.journal().onWrite(sampleEvent());
            try backend.journal().flush(0);
            const old_total = backend._incr_bytes;
            try testing.expect(old_total > 0);
            try testing.expectEqual(old_total, backend._file_offset);

            try backend.journal().bgRewrite(&.{});
            try testing.expectEqual(old_total, backend._incr_bytes);
            try testing.expectEqual(0, backend._file_offset);

            var reap_result: PersistenceState.ReapResult = .running;
            var tries: usize = 0;
            while (reap_result == .running) {
                reap_result = state.reapAof();
                tries += 1;
                if (tries > 100_000) return error.ChildNeverReaped;
            }
            try testing.expectEqual(PersistenceState.ReapResult.succeeded, reap_result);

            try backend.journal().onWrite(sampleEvent());
            try backend.journal().flush(0);

            const new_incr_name = try Manifest.incrName(testing.allocator, config.append_filename, backend._incr_seq);
            defer testing.allocator.free(new_incr_name);
            const new_incr_file = try dir.openFile(io, new_incr_name, .{});
            defer new_incr_file.close(io);
            const new_incr_size = try new_incr_file.length(io);

            try testing.expectEqual(new_incr_size, backend._file_offset);
            try testing.expectEqual(old_total + new_incr_size, backend._incr_bytes);
        }
    }.run);
}

test "successful finishRewrite publishes the new base and removes retired files" {
    try withScratchDir("scratch-aof-finish-rewrite-success", struct {
        fn run(io: std.Io, dir: std.Io.Dir) !void {
            const testing = std.testing;
            var state = PersistenceState.init(io, false);
            const config: Config = .{ .append_dirname = "scratch-aof-finish-rewrite-success" };

            var backend = try AofBackend.init(io, testing.allocator, &state, config);
            defer backend.journal().deinit() catch {};

            try backend.journal().onWrite(sampleEvent());
            try backend.journal().flush(0);

            const new_live_file = try dir.createFile(io, "appendonly.aof.3.incr", .{});
            backend._file.?.close(io);
            backend._file = new_live_file;
            backend._incr_seq = 3;
            backend._file_offset = 0;
            backend._encoder.resetDbTracking();
            backend._pending_base_seq = 2;
            backend._last_rewrite_attempt_ms = 1;

            var cut_incrs = [_]Manifest.Entry{
                .{ .name = "appendonly.aof.1.incr", .seq = 1, .kind = .incr },
                .{ .name = "appendonly.aof.3.incr", .seq = 3, .kind = .incr },
            };
            try Manifest.write(io, testing.allocator, dir, "appendonly.aof.manifest", .{
                .base = null,
                .incrs = &cut_incrs,
            });
            try dir.writeFile(io, .{ .sub_path = "appendonly.aof.2.base", .data = "base" });

            try backend.journal().onWrite(sampleEvent());
            try backend.journal().flush(0);
            const live_size = backend._file_offset;

            try backend.journal().finishRewrite(.succeeded);

            const manifest = try Manifest.read(
                io,
                testing.allocator,
                dir,
                "appendonly.aof.manifest",
            ) orelse return error.TestUnexpectedResult;
            defer manifest.deinit(testing.allocator);

            try testing.expectEqual(@as(u32, 2), manifest.base.?.seq);
            try testing.expectEqualStrings("appendonly.aof.2.base", manifest.base.?.name);
            try testing.expectEqual(@as(usize, 1), manifest.incrs.len);
            try testing.expectEqual(@as(u32, 3), manifest.incrs[0].seq);
            try testing.expectError(error.FileNotFound, dir.openFile(io, "appendonly.aof.1.incr", .{}));
            try testing.expectEqual(@as(u64, 4), backend._base_size);
            try testing.expectEqual(live_size, backend._incr_bytes);
            try testing.expect(backend._pending_base_seq == null);
            try testing.expect(backend._last_rewrite_attempt_ms == null);
        }
    }.run);
}

test "failed finishRewrite removes the orphan base and preserves the cut manifest" {
    try withScratchDir("scratch-aof-finish-rewrite-failure", struct {
        fn run(io: std.Io, dir: std.Io.Dir) !void {
            const testing = std.testing;
            var state = PersistenceState.init(io, false);
            const config: Config = .{ .append_dirname = "scratch-aof-finish-rewrite-failure" };

            var backend = try AofBackend.init(io, testing.allocator, &state, config);
            defer backend.journal().deinit() catch {};

            var cut_incrs = [_]Manifest.Entry{
                .{ .name = "appendonly.aof.1.incr", .seq = 1, .kind = .incr },
                .{ .name = "appendonly.aof.3.incr", .seq = 3, .kind = .incr },
            };
            try dir.writeFile(io, .{ .sub_path = "appendonly.aof.3.incr", .data = "" });
            try Manifest.write(io, testing.allocator, dir, "appendonly.aof.manifest", .{
                .base = null,
                .incrs = &cut_incrs,
            });
            try dir.writeFile(io, .{ .sub_path = "appendonly.aof.2.base", .data = "partial" });
            backend._pending_base_seq = 2;
            backend._last_rewrite_attempt_ms = 1;

            const stderr_guard = try TestStderrGuard.silence();
            defer stderr_guard.restore();
            try backend.journal().finishRewrite(.failed);

            const manifest = try Manifest.read(
                io,
                testing.allocator,
                dir,
                "appendonly.aof.manifest",
            ) orelse return error.TestUnexpectedResult;
            defer manifest.deinit(testing.allocator);

            try testing.expect(manifest.base == null);
            try testing.expectEqual(@as(usize, 2), manifest.incrs.len);
            try testing.expectEqual(@as(u32, 1), manifest.incrs[0].seq);
            try testing.expectEqual(@as(u32, 3), manifest.incrs[1].seq);
            try testing.expectError(error.FileNotFound, dir.openFile(io, "appendonly.aof.2.base", .{}));
            try testing.expect(backend._pending_base_seq == null);
            try testing.expect(backend._last_rewrite_attempt_ms.? > 1);
        }
    }.run);
}

test "reconcile removes stale and orphaned AOF files only" {
    try withScratchDir("scratch-aof-reconcile", struct {
        fn run(io: std.Io, dir: std.Io.Dir) !void {
            const testing = std.testing;
            var state = PersistenceState.init(io, false);
            const config: Config = .{ .append_dirname = "scratch-aof-reconcile" };

            var backend = try AofBackend.init(io, testing.allocator, &state, config);
            defer backend.journal().deinit() catch {};

            var incrs = [_]Manifest.Entry{
                .{ .name = "appendonly.aof.1.incr", .seq = 1, .kind = .incr },
                .{ .name = "appendonly.aof.3.incr", .seq = 3, .kind = .incr },
            };
            const live_manifest: Manifest.Manifest = .{
                .base = .{ .name = "appendonly.aof.2.base", .seq = 2, .kind = .base },
                .incrs = &incrs,
            };

            try dir.writeFile(io, .{ .sub_path = "appendonly.aof.2.base", .data = "base" });
            try dir.writeFile(io, .{ .sub_path = "appendonly.aof.3.incr", .data = "live" });
            try dir.writeFile(io, .{ .sub_path = "appendonly.aof.4.base", .data = "partial" });
            try dir.writeFile(io, .{ .sub_path = "appendonly.aof.5.incr", .data = "old" });
            try dir.writeFile(io, .{ .sub_path = "appendonly.aof.manifest.tmp", .data = "stale" });
            try dir.writeFile(io, .{ .sub_path = "operator-backup", .data = "keep" });
            try dir.writeFile(io, .{ .sub_path = "appendonly.aof.backup", .data = "keep" });
            try dir.writeFile(io, .{ .sub_path = "appendonly.aof..base", .data = "keep" });
            try dir.writeFile(io, .{ .sub_path = "appendonly.aof.x.incr", .data = "keep" });
            try dir.writeFile(io, .{ .sub_path = "appendonly.aof.1.manifest", .data = "keep" });

            const stderr_guard = try TestStderrGuard.silence();
            defer stderr_guard.restore();
            try backend.journal().reconcile(
                io,
                testing.allocator,
                dir,
                config.append_filename,
                live_manifest,
            );

            try dir.access(io, "appendonly.aof.1.incr", .{});
            try dir.access(io, "appendonly.aof.2.base", .{});
            try dir.access(io, "appendonly.aof.3.incr", .{});
            try dir.access(io, "operator-backup", .{});
            try dir.access(io, "appendonly.aof.backup", .{});
            try dir.access(io, "appendonly.aof..base", .{});
            try dir.access(io, "appendonly.aof.x.incr", .{});
            try dir.access(io, "appendonly.aof.1.manifest", .{});
            try testing.expectError(error.FileNotFound, dir.access(io, "appendonly.aof.4.base", .{}));
            try testing.expectError(error.FileNotFound, dir.access(io, "appendonly.aof.5.incr", .{}));
            try testing.expectError(error.FileNotFound, dir.access(io, "appendonly.aof.manifest.tmp", .{}));
        }
    }.run);
}

test "reconcile refuses to delete files without an authoritative manifest" {
    try withScratchDir("scratch-aof-reconcile-no-manifest", struct {
        fn run(io: std.Io, dir: std.Io.Dir) !void {
            const testing = std.testing;
            var state = PersistenceState.init(io, false);
            const config: Config = .{ .append_dirname = "scratch-aof-reconcile-no-manifest" };

            var backend = try AofBackend.init(io, testing.allocator, &state, config);
            defer backend.journal().deinit() catch {};
            try dir.writeFile(io, .{ .sub_path = "appendonly.aof.2.base", .data = "evidence" });

            try testing.expectError(
                Journal.Error.FailedToReadManifest,
                backend.journal().reconcile(
                    io,
                    testing.allocator,
                    dir,
                    config.append_filename,
                    null,
                ),
            );
            try dir.access(io, "appendonly.aof.2.base", .{});
        }
    }.run);
}

test "a flush failure latches, and the next onWrite fails fast" {
    try withScratchDir("scratch-aof-flush-failure-latch", struct {
        fn run(io: std.Io, dir: std.Io.Dir) !void {
            _ = dir;
            const testing = std.testing;

            var state = PersistenceState.init(io, false);
            const config: Config = .{ .append_dirname = "scratch-aof-flush-failure-latch" };

            var backend = try AofBackend.init(io, testing.allocator, &state, config);
            const j = backend.journal();

            try j.onWrite(sampleEvent());

            const real_file = backend._file.?;
            backend._file = null;

            // flush's errdefer logs to the real stderr on failure -- exactly
            // what this test exercises. Redirect it for the failing call,
            // then restore it, same as cron.zig's/persistence_state.zig's
            // own tests that trigger a logged failure path.
            const devnull = std.c.open("/dev/null", .{ .ACCMODE = .WRONLY });
            if (devnull < 0) return error.OpenDevNullFailed;
            defer _ = std.c.close(devnull);

            const saved_stderr = std.c.dup(std.posix.STDERR_FILENO);
            if (saved_stderr < 0) return error.DupFailed;
            defer {
                _ = std.c.dup2(saved_stderr, std.posix.STDERR_FILENO);
                _ = std.c.close(saved_stderr);
            }
            _ = std.c.dup2(devnull, std.posix.STDERR_FILENO);

            try testing.expectError(Journal.Error.FailedToWriteIncrFile, j.flush(0));
            try testing.expect(backend._last_write_failed);
            try testing.expectError(Journal.Error.UnableToRecordWrite, j.onWrite(sampleEvent()));

            backend._file = real_file;
            try j.deinit();
        }
    }.run);
}

test "concurrent onWrite from several threads loses no bytes" {
    try withScratchDir("scratch-aof-concurrent-onwrite", struct {
        fn run(io: std.Io, dir: std.Io.Dir) !void {
            const testing = std.testing;

            var state = PersistenceState.init(io, false);
            const config: Config = .{ .append_dirname = "scratch-aof-concurrent-onwrite" };

            var backend = try AofBackend.init(io, testing.allocator, &state, config);
            defer backend.journal().deinit() catch {};
            const j = backend.journal();

            // First encode on a fresh encoder includes a SELECT; the second
            // (same db) doesn't, matching backend's own first-vs-rest split.
            var sample_encoder = AofEncoder.init();
            const first_encoded = try sample_encoder.encodeWriteEvent(testing.allocator, sampleEvent());
            sample_encoder.commitDb(first_encoded.db_index);
            const second_encoded = try sample_encoder.encodeWriteEvent(testing.allocator, sampleEvent());
            const per_write_len = second_encoded.bytes.len;
            const select_len = first_encoded.bytes.len - per_write_len;
            sample_encoder.deinit(testing.allocator, first_encoded.bytes);
            sample_encoder.deinit(testing.allocator, second_encoded.bytes);

            const thread_count = 8;
            const writes_per_thread = 100;

            const worker = struct {
                fn run(worker_journal: Journal) void {
                    for (0..writes_per_thread) |_| {
                        worker_journal.onWrite(sampleEvent()) catch unreachable;
                    }
                }
            }.run;

            var threads: [thread_count]std.Thread = undefined;
            for (&threads) |*thread| {
                thread.* = try std.Thread.spawn(.{}, worker, .{j});
            }
            for (threads) |thread| thread.join();

            try j.flush(0);

            const contents = try dir.readFileAlloc(io, "appendonly.aof.1.incr", testing.allocator, .unlimited);
            defer testing.allocator.free(contents);

            try testing.expectEqual(select_len + thread_count * writes_per_thread * per_write_len, contents.len);
        }
    }.run);
}
