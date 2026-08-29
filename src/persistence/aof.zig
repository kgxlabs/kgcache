const std = @import("std");
const Journal = @import("./journal_interface.zig");
const AofEncoder = @import("../codec/aof_encoder.zig");
const Manifest = @import("../persistence/manifest.zig");
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
// Live incr file handle, will keep the file handle for the lifetime of the process (we can because we open it in append mode)
_file: ?std.Io.File,
_incr_bytes: u64,
_incr_seq: u32,
_base_size: u64,
_last_write_failed: bool = false,
_loading: bool = false,
_buffer: std.ArrayList(u8) = .empty,

const vtable: Journal.VTable = .{
    .bgRewrite = bgRewrite,
    .deinit = deinit,
    .finishRewrite = finishRewrite,
    .flush = flush,
    .onWrite = onWrite,
};

// TODO: Refactor init. separate concerns
pub fn init(io: std.Io, allocator: std.mem.Allocator, state: *PersistenceState, config: Config) Journal.Error!AofBackend {
    const cwd = std.Io.Dir.cwd();

    cwd.createDir(io, config.append_dirname, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return Journal.Error.FailedToOpenDir,
    };

    const dir = std.Io.Dir.cwd().openDir(io, config.append_dirname, .{}) catch return Journal.Error.FailedToOpenDir;

    var incr_seq: u32 = 1;
    var base_size: u64 = 0;
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

    const incr_bytes = file.length(io) catch return Journal.Error.FailedToOpenIncrFile;

    return .{
        ._io = io,
        ._allocator = allocator,
        ._encoder = AofEncoder.init(),
        ._persistence_state = state,
        ._config = config,
        ._incr_seq = incr_seq,
        ._file = file,
        ._incr_bytes = incr_bytes,
        ._base_size = base_size,
    };
}

pub fn journal(self: *AofBackend) Journal {
    return .{
        .ptr = self,
        .vtable = &vtable,
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

pub fn bgRewrite(_: *anyopaque) Journal.Error!void {
    return;
}

pub fn finishRewrite(_: *anyopaque, _: bool) Journal.Error!void {
    return;
}

pub fn flush(ptr: *anyopaque, _: i64) Journal.Error!void {
    const self: *AofBackend = @ptrCast(@alignCast(ptr));
    errdefer |err| {
        self._last_write_failed = true;
        helpers.logStderr(self._io, "aof: failed to flush: {s}\n", .{@errorName(err)});
    }
    try flushLocked(self);
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

fn flushLocked(self: *AofBackend) Journal.Error!void {
    self._mutex.lockUncancelable(self._io);
    defer self._mutex.unlock(self._io);

    const file = self._file orelse return Journal.Error.FailedToWriteIncrFile;
    var write_buf: [1024]u8 = undefined;
    var file_writer = file.writer(self._io, &write_buf);
    file_writer.interface.writeAll(self._buffer.items) catch return Journal.Error.FailedToWriteIncrFile;
    file_writer.interface.flush() catch return Journal.Error.FailedToWriteIncrFile;

    if (self._config.append_fsync == .always) {
        file.sync(self._io) catch return Journal.Error.FailedToWriteIncrFile;
    }

    self._incr_bytes += self._buffer.items.len;
    self._buffer.clearRetainingCapacity();
    self._last_write_failed = false;
}

fn appendEvent(self: *AofBackend, event: Journal.WriteEvent) Journal.Error!void {
    const encoded = self._encoder.encode(self._allocator, event) catch return Journal.Error.OutOfMemory;
    defer self._encoder.deinit(self._allocator, encoded);

    self._mutex.lockUncancelable(self._io);
    defer self._mutex.unlock(self._io);

    self._buffer.appendSlice(self._allocator, encoded) catch return Journal.Error.FailedBufferAppend;
}
