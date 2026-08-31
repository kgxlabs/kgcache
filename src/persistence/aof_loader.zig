const std = @import("std");
const Manifest = @import("manifest.zig");
const Config = @import("../config.zig");
const ClientState = @import("../client_state.zig");
const store = @import("../store.zig");
const resp = @import("../resp.zig");
const commander = @import("../commander.zig");
const helpers = @import("../helpers.zig");

pub const Error = error{
    FailedToLoadManifestDir,
    FailedToLoadManifest,
    FailedToReadManifest,
    FailedToParseEntry,
    FailedToInitCommander,
    FailedToExecuteCommand,
};

pub fn replay(io: std.Io, allocator: std.mem.Allocator, data_store: *store.Store, config: Config) Error!void {
    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, config.append_dirname, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            helpers.logStdout(io, "aof: manifest dir not found: {s}\n", .{@errorName(err)});
        },
        else => {
            return Error.FailedToLoadManifestDir;
        },
    };
    defer dir.close(io);

    const manifest_name = Manifest.manifestName(allocator, config.append_filename) catch return Error.FailedToLoadManifest;
    const manifest = (Manifest.read(
        io,
        allocator,
        dir,
        manifest_name,
    ) catch return Error.FailedToReadManifest) orelse return null;

    const client_state = ClientState.init();

    if (manifest.base) |base| {
        const base_name = Manifest.baseName(allocator, base.name, base.seq) catch return Error.FailedToLoadManifest;
        const base_contents = dir.readFileAlloc(io, base_name, allocator, .unlimited) catch |err| switch (err) {
            error.FileNotFound => {
                helpers.logStdout(io, "aof: base aof file not found: {s}\n", @errorName(err));
                return;
            },
            error.OutOfMemory => return Error.OutOfMemory,
            else => return Error.FailedToReadManifest,
        };
        defer allocator.free(base_contents);

        try replayFile(io, allocator, data_store, client_state, base_contents);
    }
}

fn replayFile(io: std.Io, allocator: std.mem.Allocator, data_store: *store.Store, client_state: ClientState, contents: []u8) Error!void {
    while (true) {
        var parser = resp.parser(contents);
        const command = parser.next(allocator) catch |err| {
            helpers.logStderr(io, "aof_loader: Failed to parse command: {s}\n", .{@errorName(err)});
            return Error.FailedToParseEntry;
        };
        defer parser.deinit(allocator, command);
        if (command == null) break;

        const c = commander.init(allocator, command) catch |err| {
            helpers.logStderr(io, "aof_loader: Failed to failed to initialize commander: {s}\n", .{@errorName(err)});
            return Error.FailedToInitCommander;
        };
        defer c.deinit();

        c.execute(io, data_store, &client_state) catch |err| {
            helpers.logStderr(io, "aof_loader: Failed to execute command: {s}\n", .{@errorName(err)});
            return Error.FailedToExecuteCommand;
        };
    }
}
