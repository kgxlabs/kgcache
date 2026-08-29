const std = @import("std");
const Journal = @import("./journal_interface.zig");
const AofEncoder = @import("../codec/aof_encoder.zig");
const Manifest = @import("../persistence/manifest.zig");
const PersistenceState = @import("../persistence_state.zig");
const Config = @import("../config.zig");

const AofBackend = @This();

_io: std.Io,
_allocator: std.mem.Allocator,
_encoder: AofEncoder,
_persistence_state: *PersistenceState,
_config: Config,
// Live incr file handle, will keep the file handle for the lifetime of the process (we can because we open it in append mode)
_file: ?std.Io.File,
_incr_bytes: u64,
_incr_seq: u32,

const vtable: Journal.VTable = .{
    .bgRewrite = bgRewrite,
    .close = close,
    .finishRewrite = finishRewrite,
    .flush = flush,
    .onWrite = onWrite,
};

pub fn init(io: std.Io, allocator: std.mem.Allocator, state: *PersistenceState, config: Config) Journal.Error!AofBackend {
    const cwd = std.Io.Dir.cwd();

    cwd.createDir(io, config.append_dirname, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return Journal.Error.FailedToOpenDir,
    };

    const dir = std.Io.Dir.cwd().openDir(io, config.append_dirname, .{}) catch return Journal.Error.FailedToOpenDir;

    var incr_seq: u32 = 1;
    const read_manifest_name = Manifest.manifestName(allocator, config.append_filename) catch return Journal.Error.FailedToReadManifest;
    defer allocator.free(read_manifest_name);

    const maybe_manifest = Manifest.read(
        io,
        allocator,
        dir,
        read_manifest_name,
    ) catch return Journal.Error.FailedToReadManifest;

    const incr_name = Manifest.incrName(allocator, config.append_filename, incr_seq) catch return Journal.Error.FailedToWriteManifest;
    defer allocator.free(incr_name);

    if (maybe_manifest) |manifest| {
        defer manifest.deinit(allocator);
        incr_seq = Manifest.nextSeq(manifest);
    } else {
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

    const file = dir.openFile(io, config.append_filename, .{ .mode = .read_write }) catch |err| switch (err) {
        error.FileNotFound => dir.createFile(io, incr_name, .{}) catch return Journal.Error.FailedToOpenManifest,
        else => return Journal.Error.FailedToOpenManifest,
    };

    const incr_bytes = file.length(io) catch return Journal.Error.FailedToOpenManifest;

    return .{
        ._io = io,
        ._allocator = allocator,
        ._encoder = AofEncoder.init(),
        ._persistence_state = state,
        ._config = config,
        ._incr_seq = incr_seq,
        ._file = file,
        ._incr_bytes = incr_bytes,
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

    const encoded = self._encoder.encode(self._allocator, event) catch return Journal.Error.OutOfMemory;
    defer self._encoder.deinit(self._allocator, encoded);

    // TODO: append `encoded` to the AOF file on disk. Needs its own design
    // pass (append-mode file handle, buffering/fsync policy) — out of scope
    // for wiring up the encoder itself.
}

pub fn bgRewrite(_: *anyopaque) Journal.Error!void {
    return;
}

pub fn finishRewrite(_: *anyopaque, _: bool) Journal.Error!void {
    return;
}

pub fn flush(_: *anyopaque, _: i64) Journal.Error!void {
    return;
}

pub fn close(_: *anyopaque) Journal.Error!void {
    return;
}
