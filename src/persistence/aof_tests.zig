const std = @import("std");
const Journal = @import("journal_interface.zig");
const AofEncoder = @import("../codec/aof_encoder.zig");
const Manifest = @import("manifest.zig");
const PersistenceState = @import("../persistence_state.zig");
const Config = @import("../config.zig");
const time = @import("../time.zig");
const AofBackend = @import("aof.zig");
const withScratchDir = @import("aof_test_helpers.zig").withScratchDir;

fn sampleEvent() Journal.WriteEvent {
    return .{ .put = .{
        .db_index = 0,
        .key = "foo",
        .value = .{ .string = "bar" },
        .expires_at = null,
    } };
}

test "ending a journal session allows another session to begin" {
    try withScratchDir("scratch-aof-journal-session-reentry", struct {
        fn run(io: std.Io, _: std.Io.Dir) !void {
            var state = PersistenceState.init(io, .{ .mutual_exclusive = false });
            const config: Config = .{ .append_dirname = "scratch-aof-journal-session-reentry" };
            var backend = try AofBackend.init(io, std.testing.allocator, &state, config);
            defer backend.journal().deinit() catch {};
            const journal_handle = backend.journal();

            var first = try journal_handle.begin();
            first.end();

            var second = try journal_handle.begin();
            second.end();
        }
    }.run);
}

test "journal begin serializes two concurrent callers" {
    try withScratchDir("scratch-aof-journal-session-serialization", struct {
        const Context = struct {
            journal: Journal,
            attempting: std.atomic.Value(bool) = .init(false),
            entered: std.atomic.Value(bool) = .init(false),
        };

        fn worker(context: *Context) void {
            context.attempting.store(true, .release);
            var tx = context.journal.begin() catch unreachable;
            context.entered.store(true, .release);
            tx.end();
        }

        fn run(io: std.Io, _: std.Io.Dir) !void {
            var state = PersistenceState.init(io, .{ .mutual_exclusive = false });
            const config: Config = .{ .append_dirname = "scratch-aof-journal-session-serialization" };
            var backend = try AofBackend.init(io, std.testing.allocator, &state, config);
            defer backend.journal().deinit() catch {};
            const journal_handle = backend.journal();

            var first = try journal_handle.begin();
            var context: Context = .{ .journal = journal_handle };
            const thread = try std.Thread.spawn(.{}, worker, .{&context});

            while (!context.attempting.load(.acquire)) std.atomic.spinLoopHint();
            try std.testing.expect(!context.entered.load(.acquire));

            first.end();
            thread.join();
            try std.testing.expect(context.entered.load(.acquire));
        }
    }.run);
}

test "dueForRewrite is false below the min size even after huge growth" {
    try withScratchDir("scratch-aof-rewrite-below-min", struct {
        fn run(io: std.Io, _: std.Io.Dir) !void {
            const testing = std.testing;
            var state = PersistenceState.init(io, .{ .mutual_exclusive = false });
            const config: Config = .{
                .append_only = true,
                .append_dirname = "scratch-aof-rewrite-below-min",
                .auto_aof_rewrite_percentage = 100,
                .auto_aof_rewrite_min_size = 1_000,
            };

            var backend = try AofBackend.init(io, testing.allocator, &state, config);
            defer backend.journal().deinit() catch {};
            backend._base_size = 1;
            backend._incr_bytes = 998;

            const journal_handle = backend.journal();
            var tx = try journal_handle.begin();
            defer tx.end();
            try testing.expect(!(try journal_handle.dueForRewrite(config)));
        }
    }.run);
}

test "dueForRewrite is true once growth and min size are both met" {
    try withScratchDir("scratch-aof-rewrite-due", struct {
        fn run(io: std.Io, _: std.Io.Dir) !void {
            const testing = std.testing;
            var state = PersistenceState.init(io, .{ .mutual_exclusive = false });
            const config: Config = .{
                .append_only = true,
                .append_dirname = "scratch-aof-rewrite-due",
                .auto_aof_rewrite_percentage = 100,
                .auto_aof_rewrite_min_size = 200,
            };

            var backend = try AofBackend.init(io, testing.allocator, &state, config);
            defer backend.journal().deinit() catch {};
            backend._base_size = 100;
            backend._incr_bytes = 100;

            const journal_handle = backend.journal();
            var tx = try journal_handle.begin();
            defer tx.end();
            try testing.expect(try journal_handle.dueForRewrite(config));
        }
    }.run);
}

test "dueForRewrite treats a zero base size as reduce-to-min-size-only" {
    try withScratchDir("scratch-aof-rewrite-zero-base", struct {
        fn run(io: std.Io, _: std.Io.Dir) !void {
            const testing = std.testing;
            var state = PersistenceState.init(io, .{ .mutual_exclusive = false });
            const config: Config = .{
                .append_only = true,
                .append_dirname = "scratch-aof-rewrite-zero-base",
                .auto_aof_rewrite_percentage = std.math.maxInt(u32),
                .auto_aof_rewrite_min_size = 100,
            };

            var backend = try AofBackend.init(io, testing.allocator, &state, config);
            defer backend.journal().deinit() catch {};
            backend._base_size = 0;
            backend._incr_bytes = 100;

            const journal_handle = backend.journal();
            var tx = try journal_handle.begin();
            defer tx.end();
            try testing.expect(try journal_handle.dueForRewrite(config));
        }
    }.run);
}

test "dueForRewrite is false when the percentage is zero" {
    try withScratchDir("scratch-aof-rewrite-disabled", struct {
        fn run(io: std.Io, _: std.Io.Dir) !void {
            const testing = std.testing;
            var state = PersistenceState.init(io, .{ .mutual_exclusive = false });
            const config: Config = .{
                .append_only = true,
                .append_dirname = "scratch-aof-rewrite-disabled",
                .auto_aof_rewrite_percentage = 0,
                .auto_aof_rewrite_min_size = 1,
            };

            var backend = try AofBackend.init(io, testing.allocator, &state, config);
            defer backend.journal().deinit() catch {};
            backend._base_size = 1;
            backend._incr_bytes = 1_000;

            const journal_handle = backend.journal();
            var tx = try journal_handle.begin();
            defer tx.end();
            try testing.expect(!(try journal_handle.dueForRewrite(config)));
        }
    }.run);
}

test "dueForRewrite is false while a rewrite is already running" {
    try withScratchDir("scratch-aof-rewrite-running", struct {
        fn run(io: std.Io, _: std.Io.Dir) !void {
            const testing = std.testing;
            var state = PersistenceState.init(io, .{ .mutual_exclusive = false });
            const config: Config = .{
                .append_only = true,
                .append_dirname = "scratch-aof-rewrite-running",
                .auto_aof_rewrite_min_size = 1,
            };

            var backend = try AofBackend.init(io, testing.allocator, &state, config);
            defer backend.journal().deinit() catch {};
            backend._base_size = 0;
            backend._incr_bytes = 1;

            {
                var state_tx = try state.begin();
                defer state_tx.end();
                try testing.expectEqual(PersistenceState.StartDecision.started, state.tryStartAof(.immediate));
            }
            defer {
                var state_tx = state.begin() catch unreachable;
                defer state_tx.end();
                state.finishAof();
            }

            const journal_handle = backend.journal();
            var tx = try journal_handle.begin();
            defer tx.end();
            try testing.expect(!(try journal_handle.dueForRewrite(config)));
        }
    }.run);
}

test "init creates the append directory and a seq-1 manifest on first boot" {
    try withScratchDir("scratch-aof-init-first-boot", struct {
        fn run(io: std.Io, dir: std.Io.Dir) !void {
            const testing = std.testing;

            var state = PersistenceState.init(io, .{ .mutual_exclusive = false });
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

            var state = PersistenceState.init(io, .{ .mutual_exclusive = false });
            const config: Config = .{ .append_dirname = "scratch-aof-onwrite-flush" };

            var backend = try AofBackend.init(io, testing.allocator, &state, config);
            defer backend.journal().deinit() catch {};
            const j = backend.journal();
            var tx = try j.begin();
            defer tx.end();

            try j.onWrite(sampleEvent());
            try j.flush(0, .{});

            const contents = try dir.readFileAlloc(io, "appendonly.aof.1.incr", testing.allocator, .unlimited);
            defer testing.allocator.free(contents);

            try testing.expect(std.mem.indexOf(u8, contents, "SET") != null);
            try testing.expect(std.mem.indexOf(u8, contents, "foo") != null);
            try testing.expect(std.mem.indexOf(u8, contents, "bar") != null);
        }
    }.run);
}

test "prepared record is invisible until publish and abort keeps it invisible" {
    try withScratchDir("scratch-aof-prepare-record", struct {
        fn run(io: std.Io, _: std.Io.Dir) !void {
            const testing = std.testing;

            var state = PersistenceState.init(io, .{ .mutual_exclusive = false });
            const config: Config = .{ .append_dirname = "scratch-aof-prepare-record" };

            var backend = try AofBackend.init(io, testing.allocator, &state, config);
            defer backend.journal().deinit() catch {};
            const j = backend.journal();
            var tx = try j.begin();
            defer tx.end();

            var aborted = try j.prepareRecord(sampleEvent());
            try testing.expectEqual(0, backend._buffer.items.len);
            aborted.abort();
            try testing.expectEqual(0, backend._buffer.items.len);

            var published = try j.prepareRecord(sampleEvent());
            defer published.abort();
            try testing.expectEqual(0, backend._buffer.items.len);
            published.publish();
            published.abort();
            try testing.expectEqual(.published, published.state);

            try testing.expect(std.mem.indexOf(u8, backend._buffer.items, "SELECT") != null);
            try testing.expect(std.mem.indexOf(u8, backend._buffer.items, "SET") != null);
        }
    }.run);
}

test "always publication stays buffered until an explicit required flush" {
    try withScratchDir("scratch-aof-fsync-always", struct {
        fn run(io: std.Io, dir: std.Io.Dir) !void {
            const testing = std.testing;
            var state = PersistenceState.init(io, .{ .mutual_exclusive = false });
            const config: Config = .{
                .append_dirname = "scratch-aof-fsync-always",
                .append_fsync = .always,
            };

            var backend = try AofBackend.init(io, testing.allocator, &state, config);
            defer backend.journal().deinit() catch {};
            const journal_handle = backend.journal();
            var tx = try journal_handle.begin();
            defer tx.end();
            try journal_handle.onWrite(sampleEvent());

            try testing.expect(backend._buffer.items.len > 0);
            try testing.expectEqual(0, try backend._file.?.length(io));
            try testing.expect(backend._last_fsync_ms == null);

            try journal_handle.flush(1000, .{ .mode = .if_required });

            try testing.expectEqual(0, backend._buffer.items.len);
            try testing.expect(backend._last_fsync_ms != null);
            const contents = try dir.readFileAlloc(io, "appendonly.aof.1.incr", testing.allocator, .unlimited);
            defer testing.allocator.free(contents);
            try testing.expect(std.mem.indexOf(u8, contents, "SET") != null);
        }
    }.run);
}

test "if_required flush leaves everysec and no writes for unconditional flush" {
    inline for (.{ Config.AppendFsync.always, Config.AppendFsync.everysec, Config.AppendFsync.no }) |policy| {
        try withScratchDir("scratch-aof-flush-mode-" ++ @tagName(policy), struct {
            fn run(io: std.Io, dir: std.Io.Dir) !void {
                const testing = std.testing;
                var state = PersistenceState.init(io, .{ .mutual_exclusive = false });
                const config: Config = .{
                    .append_dirname = "scratch-aof-flush-mode-" ++ @tagName(policy),
                    .append_fsync = policy,
                };

                var backend = try AofBackend.init(io, testing.allocator, &state, config);
                defer backend.journal().deinit() catch {};
                const journal_handle = backend.journal();
                var tx = try journal_handle.begin();
                defer tx.end();

                try journal_handle.onWrite(sampleEvent());
                const expected = try testing.allocator.dupe(u8, backend._buffer.items);
                defer testing.allocator.free(expected);

                try journal_handle.flush(1000, .{ .mode = .if_required });

                if (policy != .always) {
                    try testing.expectEqualSlices(u8, expected, backend._buffer.items);
                    try testing.expectEqual(0, try backend._file.?.length(io));
                    try testing.expect(backend._last_fsync_ms == null);
                    try journal_handle.flush(1000, .{});
                }

                try testing.expectEqual(0, backend._buffer.items.len);
                const expected_fsync_ms: ?time.UnixMs = if (policy == .no) null else 1000;
                try testing.expectEqual(expected_fsync_ms, backend._last_fsync_ms);
                const contents = try dir.readFileAlloc(io, "appendonly.aof.1.incr", testing.allocator, .unlimited);
                defer testing.allocator.free(contents);
                try testing.expectEqualSlices(u8, expected, contents);
            }
        }.run);
    }
}

test "everysec does not fsync more than once per second" {
    try withScratchDir("scratch-aof-fsync-everysec", struct {
        fn run(io: std.Io, dir: std.Io.Dir) !void {
            _ = dir;
            const testing = std.testing;
            var state = PersistenceState.init(io, .{ .mutual_exclusive = false });
            const config: Config = .{
                .append_dirname = "scratch-aof-fsync-everysec",
                .append_fsync = .everysec,
            };

            var backend = try AofBackend.init(io, testing.allocator, &state, config);
            defer backend.journal().deinit() catch {};
            backend._last_fsync_ms = 1000;
            const journal_handle = backend.journal();
            var tx = try journal_handle.begin();
            defer tx.end();

            try journal_handle.onWrite(sampleEvent());
            try journal_handle.flush(1999, .{});
            try testing.expectEqual(@as(?time.UnixMs, 1000), backend._last_fsync_ms);

            try journal_handle.flush(2000, .{});
            try testing.expectEqual(@as(?time.UnixMs, 2000), backend._last_fsync_ms);
        }
    }.run);
}

test "everysec retries after a failed flush" {
    try withScratchDir("scratch-aof-fsync-retry", struct {
        fn run(io: std.Io, dir: std.Io.Dir) !void {
            _ = dir;
            const testing = std.testing;
            var state = PersistenceState.init(io, .{ .mutual_exclusive = false });
            const config: Config = .{
                .append_dirname = "scratch-aof-fsync-retry",
                .append_fsync = .everysec,
            };

            var backend = try AofBackend.init(io, testing.allocator, &state, config);
            const j = backend.journal();
            backend._last_fsync_ms = 0;
            {
                var tx = try j.begin();
                defer tx.end();
                try j.onWrite(sampleEvent());

                const file = backend._file.?;
                backend._file = null;

                try testing.expectError(Journal.Error.MissingLiveAofFile, j.flush(1000, .{}));
                try testing.expectEqual(@as(?time.UnixMs, 0), backend._last_fsync_ms);

                backend._file = file;
                try j.flush(1000, .{});
                try testing.expectEqual(@as(?time.UnixMs, 1000), backend._last_fsync_ms);
                try testing.expect(!backend._last_write_failed);
            }
            try j.deinit();
        }
    }.run);
}

test "required flush returns file source errors and retries the published write" {
    try withScratchDir("scratch-aof-source-flush-retry", struct {
        fn run(io: std.Io, dir: std.Io.Dir) !void {
            const testing = std.testing;
            const Fail = struct {
                fn write(_: ?*anyopaque, _: std.Io.File, _: []const u8, _: []const []const u8, _: usize, _: u64) std.Io.File.WritePositionalError!usize {
                    return error.InputOutput;
                }

                fn sync(_: ?*anyopaque, _: std.Io.File) std.Io.File.SyncError!void {
                    return error.InputOutput;
                }
            };

            var state = PersistenceState.init(io, .{ .mutual_exclusive = false });
            const config: Config = .{
                .append_dirname = "scratch-aof-source-flush-retry",
                .append_fsync = .always,
            };
            var backend = try AofBackend.init(io, testing.allocator, &state, config);
            defer backend.journal().deinit() catch {};
            const journal_handle = backend.journal();
            var tx = try journal_handle.begin();
            defer tx.end();

            const stages = [_]enum { write, sync }{ .write, .sync };
            for (stages, 0..) |stage, index| {
                try journal_handle.onWrite(sampleEvent());
                var failed_vtable = io.vtable.*;
                switch (stage) {
                    .write => failed_vtable.fileWritePositional = Fail.write,
                    .sync => failed_vtable.fileSync = Fail.sync,
                }
                backend._io = .{ .userdata = io.userdata, .vtable = &failed_vtable };
                defer backend._io = io;
                const flush_time: i64 = @intCast((index + 1) * 1000);
                const source: anyerror = switch (stage) {
                    .write => error.WriteFailed,
                    .sync => error.InputOutput,
                };
                try testing.expectError(source, journal_handle.flush(flush_time, .{ .mode = .if_required }));
                try testing.expect(backend._last_write_failed);
                try testing.expect(backend._buffer.items.len > 0);

                backend._io = io;
                try journal_handle.flush(flush_time, .{ .mode = .if_required });
                try testing.expect(!backend._last_write_failed);
                try testing.expectEqual(@as(usize, 0), backend._buffer.items.len);
            }

            const file = try dir.openFile(io, "appendonly.aof.1.incr", .{});
            defer file.close(io);
            try testing.expectEqual(backend._file_offset, try file.length(io));
        }
    }.run);
}

test "no policy flushes without fsync" {
    try withScratchDir("scratch-aof-fsync-no", struct {
        fn run(io: std.Io, dir: std.Io.Dir) !void {
            const testing = std.testing;
            var state = PersistenceState.init(io, .{ .mutual_exclusive = false });
            const config: Config = .{
                .append_dirname = "scratch-aof-fsync-no",
                .append_fsync = .no,
            };

            var backend = try AofBackend.init(io, testing.allocator, &state, config);
            defer backend.journal().deinit() catch {};
            const journal_handle = backend.journal();
            var tx = try journal_handle.begin();
            defer tx.end();
            try journal_handle.onWrite(sampleEvent());
            try journal_handle.flush(5000, .{});

            try testing.expect(backend._last_fsync_ms == null);
            const contents = try dir.readFileAlloc(io, "appendonly.aof.1.incr", testing.allocator, .unlimited);
            defer testing.allocator.free(contents);
            try testing.expect(std.mem.indexOf(u8, contents, "SET") != null);
        }
    }.run);
}

test "onWrite alone leaves the file untouched" {
    try withScratchDir("scratch-aof-onwrite-buffers", struct {
        fn run(io: std.Io, dir: std.Io.Dir) !void {
            const testing = std.testing;

            var state = PersistenceState.init(io, .{ .mutual_exclusive = false });
            const config: Config = .{ .append_dirname = "scratch-aof-onwrite-buffers" };

            var backend = try AofBackend.init(io, testing.allocator, &state, config);
            defer backend.journal().deinit() catch {};
            const journal_handle = backend.journal();
            var tx = try journal_handle.begin();
            defer tx.end();

            try journal_handle.onWrite(sampleEvent());

            const file = try dir.openFile(io, "appendonly.aof.1.incr", .{});
            defer file.close(io);
            try testing.expectEqual(0, try file.length(io));
        }
    }.run);
}

test "clean shutdown flushes no-policy writes without forcing fsync" {
    try withScratchDir("scratch-aof-shutdown-no-fsync", struct {
        fn run(io: std.Io, dir: std.Io.Dir) !void {
            const testing = std.testing;

            var state = PersistenceState.init(io, .{ .mutual_exclusive = false });
            const config: Config = .{
                .append_dirname = "scratch-aof-shutdown-no-fsync",
                .append_fsync = .no,
            };

            var backend = try AofBackend.init(io, testing.allocator, &state, config);
            const journal_handle = backend.journal();
            {
                var tx = try journal_handle.begin();
                defer tx.end();
                try journal_handle.onWrite(sampleEvent());
            }
            try backend.journal().deinit();

            try testing.expect(backend._last_fsync_ms == null);
            const contents = try dir.readFileAlloc(io, "appendonly.aof.1.incr", testing.allocator, .unlimited);
            defer testing.allocator.free(contents);
            try testing.expect(std.mem.indexOf(u8, contents, "SET") != null);
        }
    }.run);
}

test "clean shutdown forces everysec writes to durable storage" {
    try withScratchDir("scratch-aof-shutdown-everysec-fsync", struct {
        fn run(io: std.Io, dir: std.Io.Dir) !void {
            _ = dir;
            const testing = std.testing;

            var state = PersistenceState.init(io, .{ .mutual_exclusive = false });
            const config: Config = .{
                .append_dirname = "scratch-aof-shutdown-everysec-fsync",
                .append_fsync = .everysec,
            };

            var backend = try AofBackend.init(io, testing.allocator, &state, config);
            const future_fsync_ms: time.UnixMs = std.math.maxInt(time.UnixMs);
            backend._last_fsync_ms = future_fsync_ms;
            const journal_handle = backend.journal();
            {
                var tx = try journal_handle.begin();
                defer tx.end();
                try journal_handle.onWrite(sampleEvent());
            }
            try backend.journal().deinit();

            try testing.expect(backend._last_fsync_ms != future_fsync_ms);
        }
    }.run);
}

test "init reopens the existing live incr file and appends after its existing contents rather than truncating it" {
    try withScratchDir("scratch-aof-reopen-no-truncate", struct {
        fn run(io: std.Io, dir: std.Io.Dir) !void {
            const testing = std.testing;
            const config: Config = .{ .append_dirname = "scratch-aof-reopen-no-truncate" };

            {
                var state = PersistenceState.init(io, .{ .mutual_exclusive = false });
                var backend = try AofBackend.init(io, testing.allocator, &state, config);
                const journal_handle = backend.journal();
                {
                    var tx = try journal_handle.begin();
                    defer tx.end();
                    try journal_handle.onWrite(sampleEvent());
                    try journal_handle.flush(0, .{});
                }
                try backend.journal().deinit();
            }

            const before = try dir.readFileAlloc(io, "appendonly.aof.1.incr", testing.allocator, .unlimited);
            defer testing.allocator.free(before);
            try testing.expect(before.len > 0);

            var state2 = PersistenceState.init(io, .{ .mutual_exclusive = false });
            var backend2 = try AofBackend.init(io, testing.allocator, &state2, config);
            defer backend2.journal().deinit() catch {};

            try testing.expectEqual(before.len, backend2._incr_bytes);
            try testing.expectEqual(before.len, backend2._file_offset);

            const journal_handle = backend2.journal();
            var tx = try journal_handle.begin();
            defer tx.end();
            try journal_handle.onWrite(sampleEvent());
            try journal_handle.flush(0, .{});

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

            var state = PersistenceState.init(io, .{ .mutual_exclusive = false });
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
            var state = PersistenceState.init(io, .{ .mutual_exclusive = false });
            const config: Config = .{ .append_dirname = "scratch-aof-rewrite-cut-byte-accounting" };

            var backend = try AofBackend.init(io, testing.allocator, &state, config);
            defer backend.journal().deinit() catch {};
            const journal_handle = backend.journal();
            var tx = try journal_handle.begin();
            defer tx.end();

            try journal_handle.onWrite(sampleEvent());
            try journal_handle.flush(0, .{});
            const old_total = backend._incr_bytes;
            try testing.expect(old_total > 0);
            try testing.expectEqual(old_total, backend._file_offset);

            _ = try journal_handle.bgRewrite(&.{}, .manual);
            try testing.expectEqual(old_total, backend._incr_bytes);
            try testing.expectEqual(0, backend._file_offset);

            var reap_result: PersistenceState.ReapResult = .running;
            var tries: usize = 0;
            while (reap_result == .running) {
                var state_tx = try state.begin();
                reap_result = state.reapAof().status;
                state_tx.end();
                tries += 1;
                if (tries > 10_000) return error.ChildNeverReaped;
                try testing.io.sleep(.fromMilliseconds(1), .awake);
            }
            try testing.expectEqual(PersistenceState.ReapResult.succeeded, reap_result);

            try journal_handle.onWrite(sampleEvent());
            try journal_handle.flush(0, .{});

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
            var state = PersistenceState.init(io, .{ .mutual_exclusive = false });
            const config: Config = .{ .append_dirname = "scratch-aof-finish-rewrite-success" };

            var backend = try AofBackend.init(io, testing.allocator, &state, config);
            defer backend.journal().deinit() catch {};
            const journal_handle = backend.journal();
            var tx = try journal_handle.begin();
            defer tx.end();

            try journal_handle.onWrite(sampleEvent());
            try journal_handle.flush(0, .{});

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

            try journal_handle.onWrite(sampleEvent());
            try journal_handle.flush(0, .{});
            const live_size = backend._file_offset;

            try journal_handle.finishRewrite(.succeeded);

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
            var state = PersistenceState.init(io, .{ .mutual_exclusive = false });
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

            const journal_handle = backend.journal();
            var tx = try journal_handle.begin();
            defer tx.end();
            try journal_handle.finishRewrite(.failed);

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
            var state = PersistenceState.init(io, .{ .mutual_exclusive = false });
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
            var state = PersistenceState.init(io, .{ .mutual_exclusive = false });
            const config: Config = .{ .append_dirname = "scratch-aof-reconcile-no-manifest" };

            var backend = try AofBackend.init(io, testing.allocator, &state, config);
            defer backend.journal().deinit() catch {};
            try dir.writeFile(io, .{ .sub_path = "appendonly.aof.2.base", .data = "evidence" });

            try testing.expectError(
                Journal.Error.MissingAofManifest,
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

            var state = PersistenceState.init(io, .{ .mutual_exclusive = false });
            const config: Config = .{ .append_dirname = "scratch-aof-flush-failure-latch" };

            var backend = try AofBackend.init(io, testing.allocator, &state, config);
            const j = backend.journal();
            {
                var tx = try j.begin();
                defer tx.end();

                try j.onWrite(sampleEvent());

                const real_file = backend._file.?;
                backend._file = null;

                try testing.expectError(Journal.Error.MissingLiveAofFile, j.flush(0, .{}));
                try testing.expect(backend._last_write_failed);
                try testing.expectError(Journal.Error.JournalWriteBlocked, j.onWrite(sampleEvent()));

                backend._file = real_file;
            }
            try j.deinit();
        }
    }.run);
}

test "concurrent onWrite from several threads loses no bytes" {
    try withScratchDir("scratch-aof-concurrent-onwrite", struct {
        fn run(io: std.Io, dir: std.Io.Dir) !void {
            const testing = std.testing;

            var state = PersistenceState.init(io, .{ .mutual_exclusive = false });
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
                        var tx = worker_journal.begin() catch unreachable;
                        defer tx.end();
                        worker_journal.onWrite(sampleEvent()) catch unreachable;
                    }
                }
            }.run;

            var threads: [thread_count]std.Thread = undefined;
            for (&threads) |*thread| {
                thread.* = try std.Thread.spawn(.{}, worker, .{j});
            }
            for (threads) |thread| thread.join();

            {
                var tx = try j.begin();
                defer tx.end();
                try j.flush(0, .{});
            }

            const contents = try dir.readFileAlloc(io, "appendonly.aof.1.incr", testing.allocator, .unlimited);
            defer testing.allocator.free(contents);

            try testing.expectEqual(select_len + thread_count * writes_per_thread * per_write_len, contents.len);
        }
    }.run);
}
