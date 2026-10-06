const std = @import("std");
const support = @import("server_process");
const resp_client = @import("../harness/resp_client.zig");

const Persistence = enum { snapshot, aof };
const Directory = enum { relative, absolute };
const persistence_dir = "persistence \"files\"";
const file_persistence_dir = "persistence \\\"files\\\"";

pub fn run(io: std.Io, allocator: std.mem.Allocator, executable_path: []const u8, artifact_dir: ?[]const u8) !void {
    std.log.info("integration: config names and persistence paths started", .{});

    try checkListenerOverrides(io, allocator, executable_path, artifact_dir);
    for ([_]Directory{ .relative, .absolute }) |directory| {
        for ([_]Persistence{ .snapshot, .aof }) |persistence| {
            try checkPersistence(io, allocator, executable_path, artifact_dir, directory, persistence);
        }
    }
    try checkCliOverrides(io, allocator, executable_path, artifact_dir);

    std.log.info("integration: config names and persistence paths passed", .{});
}

fn checkListenerOverrides(io: std.Io, allocator: std.mem.Allocator, executable_path: []const u8, artifact_dir: ?[]const u8) !void {
    const control = try support.ServerProcess.create(io, allocator, executable_path, .{ .artifact_dir = artifact_dir });
    defer control.destroy();
    errdefer control.failed = true;

    try expectPing(io, control);
    const occupied_port = control.address.?.getPort();
    const extra_config = try std.fmt.allocPrint(allocator, "bind \"0.0.0.0\"\nport \"{d}\"\n", .{occupied_port});
    defer allocator.free(extra_config);

    const overrides = &[_][]const u8{ "--bind", "127.0.0.1", "--port", "0" };
    const cases = [_]struct { config_subpath: ?[]const u8, config_arg_index: usize }{
        .{ .config_subpath = "kgcache.conf", .config_arg_index = 0 },
        .{ .config_subpath = "kgcache.conf", .config_arg_index = 2 },
        .{ .config_subpath = "kgcache.conf", .config_arg_index = overrides.len },
        .{ .config_subpath = "./-cache.conf", .config_arg_index = 0 },
        .{ .config_subpath = null, .config_arg_index = 0 },
    };

    for (cases) |case| {
        const target = try support.ServerProcess.create(io, allocator, executable_path, .{
            .config_subpath = case.config_subpath,
            .config_arg_index = case.config_arg_index,
            .extra_config = extra_config,
            .extra_args = overrides,
            .artifact_dir = artifact_dir,
        });
        defer target.destroy();
        errdefer target.failed = true;

        if (target.address.?.getPort() == occupied_port) return error.SharedPort;

        try expectPing(io, target);
        try expectPing(io, control);
        try target.stop();
    }
    try control.stop();
}

fn expectPing(io: std.Io, server: *support.ServerProcess) !void {
    const client = try server.address.?.connect(io, .{ .mode = .stream });
    defer client.close(io);
    try resp_client.sendAndExpect(io, server, client.socket.handle, "*1\r\n$4\r\nPING\r\n", "+PONG\r\n");
}

fn checkCliOverrides(io: std.Io, allocator: std.mem.Allocator, executable_path: []const u8, artifact_dir: ?[]const u8) !void {
    const server = try support.ServerProcess.createStopped(io, allocator, executable_path, .{
        .extra_config = "databases \"1\"\ndir \".\"\ndbfilename \"file.kgc\"\nappendonly \"yes\"\nsave \"60\" \"1\"\n",
        .extra_args = &.{
            "--databases",  "2",  "--dir",  "data \"files\\archive", "--dbfilename", "override.kgc",
            "--appendonly", "no", "--save", "",
        },
        .artifact_dir = artifact_dir,
    });
    defer server.destroy();
    errdefer server.failed = true;
    var working_dir = try std.Io.Dir.cwd().openDir(io, server.data_dir, .{});
    defer working_dir.close(io);
    try working_dir.createDir(io, "data \"files\\archive", .default_dir);
    try server.start();
    {
        const client = try server.address.?.connect(io, .{ .mode = .stream });
        defer client.close(io);
        const fd = client.socket.handle;
        try resp_client.sendAndExpect(io, server, fd, "*2\r\n$6\r\nSELECT\r\n$1\r\n1\r\n", "+OK\r\n");
        try resp_client.sendAndExpect(io, server, fd, "*2\r\n$6\r\nSELECT\r\n$1\r\n2\r\n", "-ERR DB index is out of range\r\n");
        try resp_client.sendAndExpect(io, server, fd, "*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$5\r\nvalue\r\n", "+OK\r\n");
        try resp_client.sendAndExpect(io, server, fd, "*1\r\n$4\r\nSAVE\r\n", "+OK\r\n");
    }
    try server.stop();
    try working_dir.access(io, "data \"files\\archive/override.kgc", .{});
    try expectMissing(io, working_dir, "file.kgc");
    try expectMissing(io, working_dir, "aof");
    try expectMissing(io, working_dir, "data \"files\\archive/aof");
}

fn checkPersistence(
    io: std.Io,
    allocator: std.mem.Allocator,
    executable_path: []const u8,
    artifact_dir: ?[]const u8,
    directory: Directory,
    persistence: Persistence,
) !void {
    std.log.info("integration: {s} persistence with {s} dir started", .{ @tagName(persistence), @tagName(directory) });

    var extra_config: ?[]u8 = null;
    defer if (extra_config) |config| allocator.free(config);

    // prepare the folder structure to start server
    const server = try support.ServerProcess.createStopped(io, allocator, executable_path, .{
        .config_subpath = "config/kgcache.conf",
        .artifact_dir = artifact_dir,
    });
    defer server.destroy();
    errdefer server.failed = true;

    // create config files
    const cwd = std.Io.Dir.cwd();
    var working_dir = try cwd.openDir(io, server.data_dir, .{});
    defer working_dir.close(io);

    try working_dir.createDir(io, persistence_dir, .default_dir);
    try working_dir.createDirPath(io, "config/" ++ persistence_dir);

    const absolute_file_dir = try std.fs.path.join(allocator, &.{ server.data_dir, file_persistence_dir });
    defer allocator.free(absolute_file_dir);

    extra_config = try std.fmt.allocPrint(
        allocator,
        "bind \"127.0.0.1\"\nport \"0\"\ndatabases \"4\"\ndir \"{s}\"\ndbfilename \"state file.kgc\"\nappenddirname \"history\"\nappendfilename \"journal.aof\"\nappendonly \"{s}\"\nappendfsync \"always\"\nsave \"3600\" \"1000000\"\n",
        .{ if (directory == .absolute) absolute_file_dir else file_persistence_dir, if (persistence == .aof) "yes" else "no" },
    );
    server.options.extra_config = extra_config.?;

    // start the server
    try server.start();
    {
        const client = try server.address.?.connect(io, .{ .mode = .stream });
        defer client.close(io);

        const fd = client.socket.handle;
        try resp_client.sendAndExpect(io, server, fd, "*1\r\n$4\r\nPING\r\n", "+PONG\r\n");
        try resp_client.sendAndExpect(io, server, fd, "*2\r\n$6\r\nSELECT\r\n$1\r\n0\r\n", "+OK\r\n");
        try resp_client.sendAndExpect(io, server, fd, "*2\r\n$6\r\nSELECT\r\n$1\r\n3\r\n", "+OK\r\n");
        try resp_client.sendAndExpect(io, server, fd, "*2\r\n$6\r\nSELECT\r\n$1\r\n4\r\n", "-ERR DB index is out of range\r\n");
        try resp_client.sendAndExpect(io, server, fd, "*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$5\r\nvalue\r\n", "+OK\r\n");
        if (persistence == .snapshot) {
            try resp_client.sendAndExpect(io, server, fd, "*1\r\n$4\r\nSAVE\r\n", "+OK\r\n");
        }
    }
    try server.stop();

    if (persistence == .snapshot) {
        try working_dir.access(io, persistence_dir ++ "/state file.kgc", .{});
        try expectMissing(io, working_dir, persistence_dir ++ "/history");
    }

    if (persistence == .aof) {
        try working_dir.access(io, persistence_dir ++ "/history/journal.aof.manifest", .{});
        const data_file = try working_dir.openFile(io, persistence_dir ++ "/history/journal.aof.1.incr", .{});
        defer data_file.close(io);
        if (try data_file.length(io) == 0) return error.EmptyAofData;
        try expectMissing(io, working_dir, persistence_dir ++ "/state file.kgc");
    }

    for ([_][]const u8{
        "state file.kgc",
        "dump.kgc",
        "history",
        "aof",
        "appendonlydir",
        "config/" ++ persistence_dir ++ "/state file.kgc",
        "config/" ++ persistence_dir ++ "/history",
    }) |path| {
        try expectMissing(io, working_dir, path);
    }

    try server.start();
    {
        const client = try server.address.?.connect(io, .{ .mode = .stream });
        defer client.close(io);
        const fd = client.socket.handle;
        try resp_client.sendAndExpect(io, server, fd, "*2\r\n$3\r\nGET\r\n$3\r\nkey\r\n", "$-1\r\n");
        try resp_client.sendAndExpect(io, server, fd, "*2\r\n$6\r\nSELECT\r\n$1\r\n3\r\n", "+OK\r\n");
        try resp_client.sendAndExpect(io, server, fd, "*2\r\n$3\r\nGET\r\n$3\r\nkey\r\n", "$5\r\nvalue\r\n");
    }
    try server.stop();

    std.log.info("integration: {s} persistence with {s} dir passed", .{ @tagName(persistence), @tagName(directory) });
}

fn expectMissing(io: std.Io, dir: std.Io.Dir, path: []const u8) !void {
    dir.access(io, path, .{}) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    std.log.err("integration: unexpected persistence path {s}", .{path});
    return error.UnexpectedPersistencePath;
}
