const std = @import("std");
const support = @import("server_process");
const resp_client = @import("../harness/resp_client.zig");

const Persistence = enum { snapshot, aof };
const Directory = enum { relative, absolute };

pub fn run(io: std.Io, allocator: std.mem.Allocator, executable_path: []const u8, artifact_dir: ?[]const u8) !void {
    std.log.info("integration: config names and persistence paths started", .{});

    for ([_]Directory{ .relative, .absolute }) |directory| {
        for ([_]Persistence{ .snapshot, .aof }) |persistence| {
            try checkPersistence(io, allocator, executable_path, artifact_dir, directory, persistence);
        }
    }
    try checkCliOverrides(io, allocator, executable_path, artifact_dir);

    std.log.info("integration: config names and persistence paths passed", .{});
}

fn checkCliOverrides(io: std.Io, allocator: std.mem.Allocator, executable_path: []const u8, artifact_dir: ?[]const u8) !void {
    const server = try support.ServerProcess.createStopped(io, allocator, executable_path, .{
        .extra_config = "databases 1\ndir .\ndbfilename file.kgc\nappendonly yes\nsave 60 1\n",
        .extra_args = &.{
            "--databases",  "2",  "--dir",  "data files", "--dbfilename", "override.kgc",
            "--appendonly", "no", "--save", "",
        },
        .artifact_dir = artifact_dir,
    });
    defer server.destroy();
    errdefer server.failed = true;
    var working_dir = try std.Io.Dir.cwd().openDir(io, server.data_dir, .{});
    defer working_dir.close(io);
    try working_dir.createDir(io, "data files", .default_dir);
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
    try working_dir.access(io, "data files/override.kgc", .{});
    try expectMissing(io, working_dir, "file.kgc");
    try expectMissing(io, working_dir, "aof");
    try expectMissing(io, working_dir, "data files/aof");
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

    try working_dir.createDir(io, "persistence", .default_dir);
    try working_dir.createDirPath(io, "config/persistence");

    const absolute_dir = try std.fs.path.join(allocator, &.{ server.data_dir, "persistence" });
    defer allocator.free(absolute_dir);

    extra_config = try std.fmt.allocPrint(
        allocator,
        "databases 4\ndir {s}\ndbfilename state.kgc\nappenddirname history\nappendfilename journal.aof\nappendonly {s}\nappendfsync always\n",
        .{ if (directory == .absolute) absolute_dir else "persistence", if (persistence == .aof) "yes" else "no" },
    );
    server.options.extra_config = extra_config.?;

    // start the server
    try server.start();
    {
        const client = try server.address.?.connect(io, .{ .mode = .stream });
        defer client.close(io);

        const fd = client.socket.handle;
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
        try working_dir.access(io, "persistence/state.kgc", .{});
        try expectMissing(io, working_dir, "persistence/history");
    }

    if (persistence == .aof) {
        try working_dir.access(io, "persistence/history/journal.aof.manifest", .{});
        const data_file = try working_dir.openFile(io, "persistence/history/journal.aof.1.incr", .{});
        defer data_file.close(io);
        if (try data_file.length(io) == 0) return error.EmptyAofData;
        try expectMissing(io, working_dir, "persistence/state.kgc");
    }

    for ([_][]const u8{
        "state.kgc",
        "dump.kgc",
        "history",
        "aof",
        "appendonlydir",
        "config/persistence/state.kgc",
        "config/persistence/history",
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
