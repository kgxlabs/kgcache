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
