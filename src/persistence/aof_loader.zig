const std = @import("std");
const Manifest = @import("manifest.zig");
const Config = @import("../config.zig");
const ClientState = @import("../client_state.zig");
const store = @import("../store.zig");
const resp = @import("../resp.zig");
const commander = @import("../commander.zig");
const helpers = @import("../helpers.zig");

pub const Error = error{
    OutOfMemory,
    FailedToLoadManifestDir,
    FailedToLoadManifest,
    FailedToReadManifest,
    FailedToParseEntry,
    FailedToInitCommander,
    FailedToExecuteCommand,
    CorruptAof,
    TruncatedAof,
    CommandFailed,
    MissingAofFile,
    FailedToTruncateAof,
};

const ReplayResult = union(enum) {
    complete,
    truncated: usize,
};

pub const ReplayStats = struct {
    base_size: u64 = 0,
    incr_bytes: u64 = 0,
};

pub fn replay(io: std.Io, allocator: std.mem.Allocator, data_store: *store.Store, config: Config) Error!ReplayStats {
    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, config.append_dirname, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            helpers.logStdout(io, "aof: manifest dir not found: {s}\n", .{@errorName(err)});
            return .{};
        },
        else => {
            return Error.FailedToLoadManifestDir;
        },
    };
    defer dir.close(io);

    const manifest_name = Manifest.manifestName(allocator, config.append_filename) catch return Error.FailedToLoadManifest;
    defer allocator.free(manifest_name);
    const manifest = (Manifest.read(
        io,
        allocator,
        dir,
        manifest_name,
    ) catch return Error.FailedToReadManifest) orelse return .{};
    defer manifest.deinit(allocator);

    var client_state = ClientState.init();
    var stats: ReplayStats = .{};

    if (manifest.base) |base| {
        stats.base_size = try replayFile(io, allocator, data_store, &client_state, config, dir, base.name, false);
    }

    // This is already in ascending order. `Manifest.parse` guarantees it otherwise it will throw `NonAscendingIncrSeq`
    for (manifest.incrs, 0..) |incr, index| {
        const is_last = index + 1 == manifest.incrs.len;
        const size = try replayFile(io, allocator, data_store, &client_state, config, dir, incr.name, is_last);
        if (is_last) stats.incr_bytes = size;
    }

    return stats;
}

fn replayFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    data_store: *store.Store,
    client_state: *ClientState,
    config: Config,
    dir: std.Io.Dir,
    filename: []const u8,
    is_last: bool,
) Error!u64 {
    const contents = dir.readFileAlloc(io, filename, allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return Error.MissingAofFile,
        error.OutOfMemory => return Error.OutOfMemory,
        else => return Error.FailedToReadManifest,
    };
    defer allocator.free(contents);
    const result = try replayContents(
        io,
        allocator,
        contents,
        data_store,
        client_state,
        filename,
    );

    switch (result) {
        .complete => return @intCast(contents.len),
        .truncated => |safe_offset| {
            if (!is_last or !config.aof_load_truncated) {
                helpers.logStderr(io, "aof: unfinished command in {s} at byte {d}\n", .{ filename, safe_offset });
                return Error.TruncatedAof;
            }

            const file = dir.openFile(
                io,
                filename,
                .{ .mode = .read_write },
            ) catch return Error.MissingAofFile;
            defer file.close(io);

            // truncate the incomplete command from file
            file.setLength(io, @intCast(safe_offset)) catch {
                return Error.FailedToTruncateAof;
            };

            helpers.logStderr(io, "aof: removed unfinished command from {s} at byte {d}\n", .{ filename, safe_offset });
            return @intCast(safe_offset);
        },
    }
}

fn replayContents(
    io: std.Io,
    allocator: std.mem.Allocator,
    contents: []const u8,
    data_store: *store.Store,
    client_state: *ClientState,
    filename: []const u8,
) Error!ReplayResult {
    var parser = resp.parser(contents);
    while (true) {
        // TODO: we are reaching to the implementation details here. refactor
        const command_start = parser._pos;
        const maybe_value = parser.next(allocator) catch |err| switch (err) {
            error.Incomplete => {
                return .{ .truncated = command_start };
            },
            else => {
                helpers.logStderr(
                    io,
                    "aof: invalid command in {s} at byte {d}: {s}\n",
                    .{ filename, command_start, @errorName(err) },
                );
                return Error.CorruptAof;
            },
        };
        const value = maybe_value orelse return .complete;
        defer parser.deinit(allocator, value);

        const c = commander.init(allocator, value) catch |err| {
            helpers.logStderr(
                io,
                "aof: cannot initialize command in {s} at byte {d}: {s}\n",
                .{ filename, command_start, @errorName(err) },
            );
            return Error.FailedToInitCommander;
        };
        defer c.deinit();

        const reply = c.execute(io, data_store, client_state) catch |err| {
            helpers.logStderr(
                io,
                "aof: command failed in {s} at byte {d}: {s}\n",
                .{ filename, command_start, @errorName(err) },
            );
            return Error.FailedToExecuteCommand;
        };

        switch (reply) {
            .simple_error => |message| {
                helpers.logStderr(
                    io,
                    "aof: command failed in {s} at byte {d}: {s}\n",
                    .{ filename, command_start, message },
                );
                return Error.FailedToExecuteCommand;
            },
            else => {},
        }
    }
}

fn nextLegacyBulk(parser: *resp.Parser, allocator: std.mem.Allocator) Error!resp.RESPValue {
    const value = parser.next(allocator) catch return Error.TruncatedAof;
    const parsed = value orelse return Error.TruncatedAof;
    return switch (parsed) {
        .bulk_string => parsed,
        else => Error.CorruptAof,
    };
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
            _ = try replay(io, testing.allocator, &data_store, config);

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
            _ = try replay(io, testing.allocator, &data_store, config);

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
            const stats = try replay(io, testing.allocator, &data_store, config);

            const file = try dir.openFile(io, "appendonly.aof.1.incr", .{});
            defer file.close(io);
            try testing.expectEqual(@as(u64, good.len), try file.length(io));
            try testing.expectEqual(@as(u64, good.len), stats.incr_bytes);
            try testing.expectEqual(1, mock.set_calls);
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
            try testing.expectError(Error.TruncatedAof, replay(io, testing.allocator, &data_store, config));
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
            try testing.expectError(Error.TruncatedAof, replay(io, testing.allocator, &data_store, config));
        }
    }.run);
}

test "a manifest naming a missing file is fatal" {
    try withReplayDir("scratch-aof-replay-missing-file", struct {
        fn run(io: std.Io, dir: std.Io.Dir, config: Config) !void {
            try writeSingleIncrManifest(io, dir);

            var mock = MockStore.init();
            var data_store = mock.store();
            try testing.expectError(Error.MissingAofFile, replay(io, testing.allocator, &data_store, config));
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
            try testing.expectError(Error.FailedToInitCommander, replay(io, testing.allocator, &data_store, config));
        }
    }.run);
}
