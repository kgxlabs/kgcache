const std = @import("std");
const Manifest = @import("manifest.zig");
const Config = @import("../config.zig");
const ClientState = @import("../client_state.zig");
const store = @import("../store.zig");
const logging = @import("../logger.zig");
const commander = @import("../commander.zig");
const request_decoder = @import("../protocol/request_decoder.zig");

pub const FileRole = enum { base, earlier_incremental, final_incremental };

pub const ReplayPolicy = struct {
    role: FileRole,
    recover_truncated_tail: bool,
    limits: request_decoder.Limits,

    pub fn mayRecoverTail(self: ReplayPolicy) bool {
        return self.role == .final_incremental and self.recover_truncated_tail;
    }
};

pub const IncompleteTail = struct {
    safe_offset: usize,
    discarded_bytes: usize,
};

pub const ReplayOutcome = union(enum) {
    complete: usize,
    incomplete_tail: IncompleteTail,
};

pub const ReplayBytesFn = *const fn (
    io: std.Io,
    allocator: std.mem.Allocator,
    contents: []const u8,
    data_store: *store.Store,
    client_state: *ClientState,
    policy: ReplayPolicy,
) anyerror!ReplayOutcome;

pub fn replayBytes(
    io: std.Io,
    allocator: std.mem.Allocator,
    contents: []const u8,
    data_store: *store.Store,
    client_state: *ClientState,
    policy: ReplayPolicy,
) anyerror!ReplayOutcome {
    var cursor: usize = 0;
    var safe_offset: usize = 0;
    while (cursor < contents.len) {
        const outcome = try request_decoder.decode(contents[cursor..], allocator, policy.limits);
        const consumed = switch (outcome) {
            .incomplete => {
                if (!policy.mayRecoverTail()) return error.TruncatedAof;
                return .{ .incomplete_tail = .{ .safe_offset = safe_offset, .discarded_bytes = contents.len - safe_offset } };
            },
            .complete => |complete| blk: {
                var decoded = complete;
                defer decoded.deinit(allocator);
                const command = try commander.init(allocator, decoded.frame);
                defer command.deinit();
                var result = try command.execute(io, data_store, client_state);
                defer result.deinit();
                if (result.value == .error_reply) return error.InvalidAofCommandResult;
                break :blk decoded.consumed;
            },
        };
        cursor = std.math.add(usize, cursor, consumed) catch return error.LengthOverflow;
        safe_offset = cursor;
    }
    return .{ .complete = cursor };
}

pub const Error = error{
    TruncatedAof,
    MissingAofFile,
    InvalidAofCommandResult,
};

pub const ReplayStats = struct {
    base_size: u64 = 0,
    /// Total bytes across every incremental file in the manifest.
    incr_bytes: u64 = 0,
    /// Final incremental file length, used as the live writer's offset.
    file_offset: u64 = 0,
};

pub fn replay(io: std.Io, allocator: std.mem.Allocator, data_store: *store.Store, config: Config, logger: logging.Logger) !ReplayStats {
    const cwd = std.Io.Dir.cwd();
    const directory_path = try config.resolveAofDirectory(allocator);
    defer allocator.free(directory_path);

    var dir = cwd.openDir(io, directory_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer dir.close(io);

    const manifest_name = try Manifest.manifestName(allocator, config.append_filename);
    defer allocator.free(manifest_name);
    const manifest = (try Manifest.read(
        io,
        allocator,
        dir,
        manifest_name,
    )) orelse return .{};
    defer manifest.deinit(allocator);

    var client_state = ClientState.init();
    var stats: ReplayStats = .{};

    if (manifest.base) |base| {
        stats.base_size = try replayFile(io, allocator, data_store, &client_state, config, logger, dir, base.name, .base);
    }

    // This is already in ascending order. `Manifest.parse` guarantees it otherwise it will throw `NonAscendingIncrSeq`
    for (manifest.incrs, 0..) |incr, index| {
        const is_last = index + 1 == manifest.incrs.len;
        const size = try replayFile(io, allocator, data_store, &client_state, config, logger, dir, incr.name, if (is_last) .final_incremental else .earlier_incremental);
        stats.incr_bytes = std.math.add(u64, stats.incr_bytes, size) catch return error.LengthOverflow;
        if (is_last) stats.file_offset = size;
    }

    return stats;
}

fn replayFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    data_store: *store.Store,
    client_state: *ClientState,
    config: Config,
    logger: logging.Logger,
    dir: std.Io.Dir,
    filename: []const u8,
    role: FileRole,
) !u64 {
    const contents = dir.readFileAlloc(io, filename, allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return error.MissingAofFile,
        else => return err,
    };
    defer allocator.free(contents);
    const policy: ReplayPolicy = .{ .role = role, .recover_truncated_tail = config.aof_load_truncated, .limits = request_decoder.aof_limits };
    const result = try replayBytes(io, allocator, contents, data_store, client_state, policy);
    switch (result) {
        .complete => |size| return @intCast(size),
        .incomplete_tail => |tail| {
            if (!policy.mayRecoverTail()) return error.TruncatedAof;
            const file = dir.openFile(io, filename, .{ .mode = .read_write }) catch |err| switch (err) {
                error.FileNotFound => return error.MissingAofFile,
                else => return err,
            };
            defer file.close(io);
            try file.setLength(io, @intCast(tail.safe_offset));
            var buffer: [256]u8 = undefined;
            const message = std.fmt.bufPrint(&buffer, "AOF recovery: truncated unfinished tail at offset {d}, discarded {d} bytes", .{ tail.safe_offset, tail.discarded_bytes }) catch unreachable;
            logger.warn(message);
            return @intCast(tail.safe_offset);
        },
    }
}

const MockStore = @import("../store/mock_store.zig");
const testing = std.testing;

const select_db_1 = "*2\r\n$6\r\nSELECT\r\n$1\r\n1\r\n";
const set_key_base = "*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$4\r\nbase\r\n";
const set_key_first = "*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$5\r\nfirst\r\n";
const set_key_final = "*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$5\r\nfinal\r\n";
const truncated_set = "*3\r\n$3\r\nSET\r\n$3\r\nbad\r\n$5\r\npar";

fn withReplayDir(comptime name: []const u8, comptime testFn: fn (std.Io, std.Io.Dir, Config) anyerror!void) !void {
    const io = testing.io;
    const cwd = std.Io.Dir.cwd();

    cwd.deleteTree(io, name) catch {};
    defer cwd.deleteTree(io, name) catch {};

    try cwd.createDir(io, name, .default_dir);
    var dir = try cwd.openDir(io, name, .{});
    defer dir.close(io);

    var config = Config.default();
    config.append_dirname = name;
    try testFn(io, dir, config);
}

fn writeThreeFileManifest(io: std.Io, dir: std.Io.Dir) !void {
    try dir.writeFile(io, .{
        .sub_path = "appendonly.aof.manifest",
        .data = "file appendonly.aof.1.base seq 1 type b\n" ++
            "file appendonly.aof.2.incr seq 2 type i\n" ++
            "file appendonly.aof.3.incr seq 3 type i\n",
    });
}

fn writeSingleIncrManifest(io: std.Io, dir: std.Io.Dir) !void {
    try dir.writeFile(io, .{
        .sub_path = "appendonly.aof.manifest",
        .data = "file appendonly.aof.1.incr seq 1 type i\n",
    });
}

test "replay of a base and two incrs applies them in manifest order" {
    try withReplayDir("scratch-aof-replay-manifest-order", struct {
        fn run(io: std.Io, dir: std.Io.Dir, config: Config) !void {
            try writeThreeFileManifest(io, dir);
            try dir.writeFile(io, .{ .sub_path = "appendonly.aof.1.base", .data = set_key_base });
            try dir.writeFile(io, .{ .sub_path = "appendonly.aof.2.incr", .data = set_key_first });
            try dir.writeFile(io, .{ .sub_path = "appendonly.aof.3.incr", .data = set_key_final });

            var mock = MockStore.init();
            mock.num_databases_result = 16;
            var data_store = mock.store();
            _ = try replay(io, testing.allocator, &data_store, config, logging.NoopLogger.logger());

            try testing.expectEqual(3, mock.set_calls);
            try testing.expectEqualStrings("final", mock.last_set_value_copy[0..mock.last_set_value_len]);
        }
    }.run);
}

test "replay honours SELECT across files" {
    try withReplayDir("scratch-aof-replay-select-across-files", struct {
        fn run(io: std.Io, dir: std.Io.Dir, config: Config) !void {
            try dir.writeFile(io, .{
                .sub_path = "appendonly.aof.manifest",
                .data = "file appendonly.aof.1.base seq 1 type b\n" ++
                    "file appendonly.aof.2.incr seq 2 type i\n",
            });
            try dir.writeFile(io, .{ .sub_path = "appendonly.aof.1.base", .data = select_db_1 });
            try dir.writeFile(io, .{ .sub_path = "appendonly.aof.2.incr", .data = set_key_final });

            var mock = MockStore.init();
            mock.num_databases_result = 16;
            var data_store = mock.store();
            _ = try replay(io, testing.allocator, &data_store, config, logging.NoopLogger.logger());

            try testing.expectEqual(@as(?u32, 1), mock.last_set_db);
        }
    }.run);
}

test "a truncated final command is truncated away and the load succeeds" {
    try withReplayDir("scratch-aof-replay-truncated-final", struct {
        fn run(io: std.Io, dir: std.Io.Dir, config: Config) !void {
            try writeSingleIncrManifest(io, dir);
            const good = set_key_final;
            try dir.writeFile(io, .{
                .sub_path = "appendonly.aof.1.incr",
                .data = good ++ truncated_set,
            });

            var mock = MockStore.init();
            mock.num_databases_result = 16;
            var data_store = mock.store();
            var logger = logging.TestLogger.init();
            const stats = try replay(io, testing.allocator, &data_store, config, logger.logger());

            const file = try dir.openFile(io, "appendonly.aof.1.incr", .{});
            defer file.close(io);
            try testing.expectEqual(@as(u64, good.len), try file.length(io));
            try testing.expectEqual(@as(u64, good.len), stats.incr_bytes);
            try testing.expectEqual(@as(u64, good.len), stats.file_offset);
            try testing.expectEqual(1, mock.set_calls);
            const events = logger.recordedEvents();
            try testing.expectEqual(1, events.len);
            try testing.expectEqual(logging.Logger.Level.warn, events[0].level.?);
            var buffer: [256]u8 = undefined;
            const expected = try std.fmt.bufPrint(&buffer, "AOF recovery: truncated unfinished tail at offset {d}, discarded {d} bytes", .{ good.len, truncated_set.len });
            try testing.expectEqualStrings(expected, events[0].message());
        }
    }.run);
}

test "a truncated final command fails the load when aof-load-truncated is no" {
    try withReplayDir("scratch-aof-replay-truncated-disabled", struct {
        fn run(io: std.Io, dir: std.Io.Dir, original_config: Config) !void {
            try writeSingleIncrManifest(io, dir);
            try dir.writeFile(io, .{ .sub_path = "appendonly.aof.1.incr", .data = truncated_set });

            var config = original_config;
            config.aof_load_truncated = false;
            var mock = MockStore.init();
            var data_store = mock.store();
            try testing.expectError(Error.TruncatedAof, replay(io, testing.allocator, &data_store, config, logging.NoopLogger.logger()));
        }
    }.run);
}

test "truncation in the base file is fatal even with aof-load-truncated yes" {
    try withReplayDir("scratch-aof-replay-truncated-base", struct {
        fn run(io: std.Io, dir: std.Io.Dir, config: Config) !void {
            try dir.writeFile(io, .{
                .sub_path = "appendonly.aof.manifest",
                .data = "file appendonly.aof.1.base seq 1 type b\n" ++
                    "file appendonly.aof.2.incr seq 2 type i\n",
            });
            try dir.writeFile(io, .{ .sub_path = "appendonly.aof.1.base", .data = truncated_set });
            try dir.writeFile(io, .{ .sub_path = "appendonly.aof.2.incr", .data = "" });

            var mock = MockStore.init();
            var data_store = mock.store();
            try testing.expectError(Error.TruncatedAof, replay(io, testing.allocator, &data_store, config, logging.NoopLogger.logger()));
        }
    }.run);
}

test "a manifest naming a missing file is fatal" {
    try withReplayDir("scratch-aof-replay-missing-file", struct {
        fn run(io: std.Io, dir: std.Io.Dir, config: Config) !void {
            try writeSingleIncrManifest(io, dir);

            var mock = MockStore.init();
            var data_store = mock.store();
            try testing.expectError(Error.MissingAofFile, replay(io, testing.allocator, &data_store, config, logging.NoopLogger.logger()));
        }
    }.run);
}

test "an unknown command in the file is fatal" {
    try withReplayDir("scratch-aof-replay-unknown-command", struct {
        fn run(io: std.Io, dir: std.Io.Dir, config: Config) !void {
            try writeSingleIncrManifest(io, dir);
            try dir.writeFile(io, .{
                .sub_path = "appendonly.aof.1.incr",
                .data = "*1\r\n$7\r\nUNKNOWN\r\n",
            });

            var mock = MockStore.init();
            var data_store = mock.store();
            try testing.expectError(error.UnknownCommand, replay(io, testing.allocator, &data_store, config, logging.NoopLogger.logger()));
        }
    }.run);
}

test "replay preserves manifest parse errors" {
    try withReplayDir("scratch-aof-replay-invalid-manifest", struct {
        fn run(io: std.Io, dir: std.Io.Dir, config: Config) !void {
            try dir.writeFile(io, .{
                .sub_path = "appendonly.aof.manifest",
                .data = "invalid manifest line\n",
            });

            var mock = MockStore.init();
            var data_store = mock.store();
            try testing.expectError(Manifest.Error.MalformedLine, replay(io, testing.allocator, &data_store, config, logging.NoopLogger.logger()));
        }
    }.run);
}

test "replay preserves a command source error" {
    try withReplayDir("scratch-aof-replay-store-error", struct {
        fn run(io: std.Io, dir: std.Io.Dir, config: Config) !void {
            try writeSingleIncrManifest(io, dir);
            try dir.writeFile(io, .{ .sub_path = "appendonly.aof.1.incr", .data = set_key_final });

            var mock = MockStore.init();
            mock.set_result = error.TestReplayStoreFailure;
            var data_store = mock.store();
            try testing.expectError(error.TestReplayStoreFailure, replay(io, testing.allocator, &data_store, config, logging.NoopLogger.logger()));
            try testing.expectEqual(@as(usize, 1), mock.set_calls);
        }
    }.run);
}

test "an unfinished earlier incremental is fatal and leaves every file intact" {
    try withReplayDir("scratch-aof-replay-truncated-earlier", struct {
        fn run(io: std.Io, dir: std.Io.Dir, config: Config) !void {
            try writeThreeFileManifest(io, dir);
            try dir.writeFile(io, .{ .sub_path = "appendonly.aof.1.base", .data = set_key_base });
            try dir.writeFile(io, .{ .sub_path = "appendonly.aof.2.incr", .data = truncated_set });
            try dir.writeFile(io, .{ .sub_path = "appendonly.aof.3.incr", .data = set_key_final });
            var mock = MockStore.init();
            var data_store = mock.store();
            var logger = logging.TestLogger.init();

            try testing.expectError(error.TruncatedAof, replay(io, testing.allocator, &data_store, config, logger.logger()));
            const earlier = try dir.readFileAlloc(io, "appendonly.aof.2.incr", testing.allocator, .unlimited);
            defer testing.allocator.free(earlier);
            const final = try dir.readFileAlloc(io, "appendonly.aof.3.incr", testing.allocator, .unlimited);
            defer testing.allocator.free(final);
            try testing.expectEqualStrings(truncated_set, earlier);
            try testing.expectEqualStrings(set_key_final, final);
            try testing.expectEqual(1, mock.set_calls);
            try testing.expectEqual(0, logger.recordedEvents().len);
        }
    }.run);
}

test "known bad final bulk terminators fail replay without repairing bytes" {
    try withReplayDir("scratch-aof-replay-malformed-terminator", struct {
        fn run(io: std.Io, dir: std.Io.Dir, config: Config) !void {
            try writeSingleIncrManifest(io, dir);
            const bad_tails = [_][]const u8{
                "*3\r\n$3\r\nDEL\r\n$3\r\nkey\r\n$1\r\nxX",
                "*3\r\n$3\r\nDEL\r\n$3\r\nkey\r\n$1\r\nx\rX",
            };
            for (bad_tails) |tail| {
                var buffer: [128]u8 = undefined;
                const contents = try std.fmt.bufPrint(&buffer, "{s}{s}", .{ set_key_final, tail });
                try dir.writeFile(io, .{ .sub_path = "appendonly.aof.1.incr", .data = contents });
                var mock = MockStore.init();
                var data_store = mock.store();
                var logger = logging.TestLogger.init();

                try testing.expectError(error.InvalidBulkTerminator, replay(io, testing.allocator, &data_store, config, logger.logger()));
                const preserved = try dir.readFileAlloc(io, "appendonly.aof.1.incr", testing.allocator, .unlimited);
                defer testing.allocator.free(preserved);
                try testing.expectEqualStrings(contents, preserved);
                try testing.expectEqual(1, mock.set_calls);
                try testing.expectEqual(0, mock.remove_calls);
                try testing.expectEqual(0, logger.recordedEvents().len);
            }
        }
    }.run);
}

test "byte replay reports the last successful offset without executing the tail" {
    var mock = MockStore.init();
    var data_store = mock.store();
    var state = ClientState.init();
    const policy: ReplayPolicy = .{ .role = .final_incremental, .recover_truncated_tail = true, .limits = request_decoder.aof_limits };
    const result = try replayBytes(testing.io, testing.allocator, set_key_final ++ truncated_set, &data_store, &state, policy);
    try testing.expectEqual(set_key_final.len, result.incomplete_tail.safe_offset);
    try testing.expectEqual(truncated_set.len, result.incomplete_tail.discarded_bytes);
    try testing.expectEqual(1, mock.set_calls);

    try testing.expectError(error.ExpectedBulkString, replayBytes(testing.io, testing.allocator, "*3\r\n$3\r\nDEL\r\n$3\r\nkey\r\n:42\r\n", &data_store, &state, policy));
    try testing.expectEqual(0, mock.remove_calls);
}

test "byte replay releases frames commands and aggregate replies on allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, replayWithCleanup, .{});
}

fn replayWithCleanup(allocator: std.mem.Allocator) !void {
    var mock = MockStore.init();
    var data_store = mock.store();
    var state = ClientState.init();
    const contents = set_key_final ++ "*3\r\n$7\r\nCOMMAND\r\n$4\r\nINFO\r\n$3\r\nGET\r\n";
    const result = try replayBytes(testing.io, allocator, contents, &data_store, &state, .{ .role = .base, .recover_truncated_tail = true, .limits = request_decoder.aof_limits });
    try testing.expectEqual(contents.len, result.complete);
    try testing.expectEqual(1, mock.set_calls);
}
