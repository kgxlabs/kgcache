const std = @import("std");
const support = @import("server_process");

const Phase = enum { cli, file };

pub fn run(io: std.Io, allocator: std.mem.Allocator, executable_path: []const u8, artifact_dir: ?[]const u8) !void {
    std.log.info("integration: invalid config startup started", .{});

    for ([_][]const u8{
        "unknown-option yes\n",
        "num-databases 4\n",
        "append-dirname history\n",
        "append-filename journal.aof\n",
        "snapshot-path state.kgc\n",
    }) |extra_config| {
        try checkRejectedStartup(io, allocator, executable_path, artifact_dir, .{ .extra_config = extra_config }, .file, error.UnknownDirective);
    }

    const cli_cases = [_]struct {
        args: []const []const u8,
        source: anyerror,
        config_arg_index: usize = 0,
        config_subpath: ?[]const u8 = "kgcache.conf",
    }{
        .{ .args = &.{ "--unknown", "yes" }, .source = error.UnknownFlag },
        .{ .args = &.{ "--num-databases", "4" }, .source = error.UnknownFlag },
        .{ .args = &.{ "--append-dirname", "history" }, .source = error.UnknownFlag },
        .{ .args = &.{ "--append-filename", "journal.aof" }, .source = error.UnknownFlag },
        .{ .args = &.{ "--snapshot-path", "state.kgc" }, .source = error.UnknownFlag },
        .{ .args = &.{ "--Port", "0" }, .source = error.UnknownFlag },
        .{ .args = &.{"--port=0"}, .source = error.UnknownFlag },
        .{ .args = &.{"--port"}, .source = error.MissingValue },
        .{ .args = &.{"--dir"}, .source = error.MissingValue },
        .{ .args = &.{"--save"}, .source = error.MissingValue },
        .{ .args = &.{ "--save", "60" }, .source = error.MissingValue },
        .{ .args = &.{ "--port", "-1" }, .source = error.InvalidValue },
        .{ .args = &.{ "--port", "65536" }, .source = error.InvalidValue },
        .{ .args = &.{ "--databases", "0" }, .source = error.InvalidValue },
        .{ .args = &.{ "--appendonly", "YES" }, .source = error.InvalidValue },
        .{ .args = &.{ "--reuse-address", "true" }, .source = error.InvalidValue },
        .{ .args = &.{ "--appendfsync", "invalid" }, .source = error.InvalidValue },
        .{ .args = &.{ "--save", "0", "1" }, .source = error.InvalidValue },
        .{ .args = &.{ "--save", "60", "0" }, .source = error.InvalidValue },
        .{ .args = &.{ "--save", "60", "1", "--save", "0", "1" }, .source = error.InvalidValue },
        .{ .args = &.{ "--save", "60", "1", "--save", "", "--save", "0", "1" }, .source = error.InvalidValue },
        .{ .args = &.{ "--port", "invalid", "--port", "0" }, .source = error.InvalidValue },
        .{ .args = &.{ "--dir", "" }, .source = error.InvalidValue },
        .{ .args = &.{ "--dbfilename", "../state.kgc" }, .source = error.InvalidValue },
        .{ .args = &.{ "--appenddirname", "../aof" }, .source = error.InvalidValue },
        .{ .args = &.{"second.conf"}, .source = error.DuplicateConfigPath },
        .{ .args = &.{ "--port", "0", "second.conf" }, .source = error.DuplicateConfigPath },
        .{ .args = &.{ "--save", "60", "1", "2" }, .source = error.DuplicateConfigPath },
        .{ .args = &.{"--"}, .source = error.UnknownFlag, .config_arg_index = 1 },
        .{ .args = &.{"--"}, .source = error.UnknownFlag },
        .{ .args = &.{ "--port", "0", "--" }, .source = error.UnknownFlag },
        .{ .args = &.{"--"}, .source = error.UnknownFlag, .config_subpath = null },
    };
    for (cli_cases) |case| {
        try checkRejectedStartup(io, allocator, executable_path, artifact_dir, .{
            .extra_args = case.args,
            .config_arg_index = case.config_arg_index,
            .config_subpath = case.config_subpath,
        }, .cli, case.source);
    }

    const ready_cases = [_]struct { args: []const []const u8, source: anyerror }{
        .{ .args = &.{"--ready-fd"}, .source = error.MissingReadyFd },
        .{ .args = &.{ "--ready-fd", "abc" }, .source = error.InvalidReadyFd },
        .{ .args = &.{ "--ready-fd", "2" }, .source = error.InvalidReadyFd },
        .{ .args = &.{ "--ready-fd", "-3" }, .source = error.InvalidReadyFd },
        .{ .args = &.{ "--ready-fd", "+3" }, .source = error.InvalidReadyFd },
        .{ .args = &.{ "--ready-fd", "3x" }, .source = error.InvalidReadyFd },
        .{ .args = &.{ "--ready-fd", "2147483648" }, .source = error.InvalidReadyFd },
        .{ .args = &.{ "--ready-fd", "3", "--ready-fd", "4" }, .source = error.DuplicateReadyFd },
    };

    for ([_]bool{ true, false }) |with_file| {
        for (ready_cases) |case| {
            try checkRejectedStartup(io, allocator, executable_path, artifact_dir, .{
                .config_subpath = if (with_file) "kgcache.conf" else null,
                .extra_args = case.args,
                .auto_ready_fd = false,
            }, .cli, case.source);
        }
    }

    const file_cases = [_]struct { config: []const u8, args: []const []const u8, source: anyerror }{
        .{ .config = "port invalid\n", .args = &.{ "--port", "0" }, .source = error.InvalidValue },
        .{ .config = "port invalid\nport 7000\n", .args = &.{ "--port", "0" }, .source = error.InvalidValue },
        .{ .config = "appendonly YES\n", .args = &.{ "--appendonly", "no" }, .source = error.InvalidValue },
        .{ .config = "save 0 1\n", .args = &.{ "--save", "60", "1" }, .source = error.InvalidValue },
        .{ .config = "save 60 1\nsave 0 1\n", .args = &.{ "--save", "" }, .source = error.InvalidValue },
        .{ .config = "dbfilename ../state.kgc\n", .args = &.{ "--dbfilename", "state.kgc" }, .source = error.InvalidValue },
        .{ .config = "port\n", .args = &.{ "--port", "0" }, .source = error.MalformedLine },
        .{ .config = "dir \"unterminated\n", .args = &.{ "--dir", "." }, .source = error.MalformedLine },
        .{ .config = "dir \"bad\\q\"\n", .args = &.{ "--dir", "." }, .source = error.MalformedLine },
        .{ .config = "save \"60\"\"1\"\n", .args = &.{ "--save", "" }, .source = error.MalformedLine },
        .{ .config = "port \"\"\nport \"7000\"\n", .args = &.{ "--port", "0" }, .source = error.InvalidValue },
        .{ .config = "dir \"\"\n", .args = &.{ "--dir", "." }, .source = error.InvalidValue },
        .{ .config = "save \"60\" \"1\"\nsave \"\"\nsave \"0\" \"1\"\n", .args = &.{ "--save", "" }, .source = error.InvalidValue },
    };

    for (file_cases) |case| {
        try checkRejectedStartup(io, allocator, executable_path, artifact_dir, .{
            .extra_config = case.config,
            .extra_args = case.args,
        }, .file, case.source);
    }

    try checkRejectedStartup(io, allocator, executable_path, artifact_dir, .{
        .config_subpath = null,
        .extra_args = &.{ "missing.conf", "--port", "0" },
    }, .file, error.FileNotFound);

    std.log.info("integration: invalid config startup passed", .{});
}

fn checkRejectedStartup(io: std.Io, allocator: std.mem.Allocator, executable_path: []const u8, artifact_dir: ?[]const u8, options: support.Options, phase: Phase, source: anyerror) !void {
    var fixture_options = options;
    fixture_options.artifact_dir = artifact_dir;
    fixture_options.report_failures = false;

    const server = try support.ServerProcess.createStopped(io, allocator, executable_path, fixture_options);

    defer server.destroy();
    errdefer {
        server.failed = true;
        std.log.err("integration: expected startup error {s}; args: {any}; config: {s}; stdout: {s}; stderr: {s}", .{
            @errorName(source), options.extra_args, options.extra_config, server.stdout.bytes(), server.stderr.bytes(),
        });
    }

    try expectStartupExit(server);

    if (server.ready_bytes_read != 0) return error.UnexpectedReadyOutput;

    const status = server.last_exit_status orelse return error.MissingExitStatus;

    if (!std.c.W.IFEXITED(status) or std.c.W.EXITSTATUS(status) != 1) return error.WrongExitStatus;
    if (server.pid != null) return error.UnreapedChild;

    const operation = switch (phase) {
        .cli => "app: invalid command line",
        .file => "app: failed to load configuration",
    };
    const expected = try std.fmt.allocPrint(allocator, "[error] {s}: {s}\n", .{ operation, @errorName(source) });
    defer allocator.free(expected);

    if (std.mem.indexOf(u8, server.stderr.bytes(), expected) == null) return error.WrongStartupError;
    if (std.mem.count(u8, server.stderr.bytes(), "[error] ") != 1) return error.UnexpectedErrorEventCount;

    server.failed = false;
}

fn expectStartupExit(server: *support.ServerProcess) !void {
    server.start() catch |err| {
        if (err == error.StartupExited) return;
        return err;
    };

    return error.ExpectedStartupFailure;
}
