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
    .beginLoading = beginLoading,
    .endLoading = endLoading,
};

pub fn journal(self: *AofBackend) Journal {
    return .{
        .ptr = self,
        .vtable = &vtable,
    };
}

pub fn finishLoading(self: *AofBackend, base_size: u64, incr_bytes: u64) void {
    self._base_size = base_size;
    self._incr_bytes = incr_bytes;
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

pub fn beginLoading(ptr: *anyopaque) void {
    const self: *AofBackend = @ptrCast(@alignCast(ptr));
    self._loading = true;
}

pub fn endLoading(ptr: *anyopaque) void {
    const self: *AofBackend = @ptrCast(@alignCast(ptr));
    self._loading = false;
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
    // NOTE: We need to go to the exact bytes because new fresh writer starts at pos 0.
    file_writer.seekTo(self._incr_bytes) catch return Journal.Error.FailedToWriteIncrFile;
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
    self._mutex.lockUncancelable(self._io);
    defer self._mutex.unlock(self._io);

    const encoded = self._encoder.encode(self._allocator, event) catch return Journal.Error.OutOfMemory;
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
    var dir = try cwd.openDir(io, name, .{});
    defer dir.close(io);

    try testFn(io, dir);
}

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
            try dir.writeFile(io, .{ .sub_path = "appendonly.aof.3.incr", .data = "existing" });

            var state = PersistenceState.init(io, false);
            const config: Config = .{ .append_dirname = "scratch-aof-picks-highest-seq" };

            var backend = try AofBackend.init(io, testing.allocator, &state, config);
            defer backend.journal().deinit() catch {};

            try testing.expectEqual(3, backend._incr_seq);
            try testing.expectEqual(8, backend._incr_bytes);
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
            const first_encoded = try sample_encoder.encode(testing.allocator, sampleEvent());
            sample_encoder.commitDb(first_encoded.db_index);
            const second_encoded = try sample_encoder.encode(testing.allocator, sampleEvent());
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
