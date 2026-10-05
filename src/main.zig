const std = @import("std");
const Cli = @import("cli.zig");
const ConfigLoader = @import("config/loader.zig");
const Server = @import("server.zig");
const ReadyPipe = @import("readiness.zig");
const logging = @import("logger.zig");

var shutdown_event: std.Io.Event = .unset;
var shutdown_signal_number: std.atomic.Value(u32) = .init(0);
var shutdown_io: std.Io = undefined;

const ShutdownHandlers = struct {
    previous_int: std.posix.Sigaction,
    previous_term: std.posix.Sigaction,

    fn install(io: std.Io) ShutdownHandlers {
        shutdown_io = io;
        shutdown_signal_number.store(0, .release);
        shutdown_event.reset();

        // this tells OS to block SIGINT and SIGTERM signals temporarily while shutdown handler is executing
        // so that when one of the signals wont get interrupted by another.
        var mask = std.posix.sigemptyset();
        std.posix.sigaddset(&mask, .INT);
        std.posix.sigaddset(&mask, .TERM);

        const action: std.posix.Sigaction = .{
            .handler = .{ .handler = shutdownHandler },
            .mask = mask,
            .flags = 0,
        };

        var previous_int: std.posix.Sigaction = undefined;
        std.posix.sigaction(.INT, &action, &previous_int);

        var previous_term: std.posix.Sigaction = undefined;
        std.posix.sigaction(.TERM, &action, &previous_term);

        return .{
            .previous_int = previous_int,
            .previous_term = previous_term,
        };
    }

    fn restore(self: ShutdownHandlers) void {
        std.posix.sigaction(.INT, &self.previous_int, null);
        std.posix.sigaction(.TERM, &self.previous_term, null);
    }
};

const RunOutcome = union(enum) {
    server: anyerror!void,
    shutdown_signal: std.Io.Cancelable!std.posix.SIG,
};

pub fn main(init: std.process.Init) u8 {
    // Server borrows this logger. Keep its storage alive for the full Server lifetime.
    var default_logger = logging.DefaultLogger.init(init.io);
    const logger = default_logger.logger();

    // Return 0 for success and 1 for failure so callers (CI or whatever) can check the result.
    // The lifecycle already logged failures, so do not let Zig report them again.
    runApplication(init, logger) catch return 1;
    return 0;
}

fn runApplication(init: std.process.Init, logger: logging.Logger) !void {
    var cli = Cli.parse(init.gpa, init.minimal.args) catch |err| {
        logger.err("app: invalid command line", err, @errorReturnTrace());
        return err;
    };
    defer cli.deinit();

    var ready_pipe = ReadyPipe.init(init.io, cli.ready_fd);
    defer ready_pipe.close();

    // Config strings borrow argv or the file buffer kept in the application arena.
    const config = ConfigLoader.load(
        init.io,
        init.arena.allocator(),
        cli.config_path,
        cli.overrides.items,
    ) catch |err| {
        logger.err("app: failed to load configuration", err, @errorReturnTrace());
        return err;
    };

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    const shutdown_handlers = ShutdownHandlers.install(init.io);
    defer shutdown_handlers.restore();

    const server = Server.create(init.io, gpa.allocator(), config, logger) catch |err| {
        logger.err("app: failed to create server", err, @errorReturnTrace());
        return err;
    };

    var runtime_error: ?anyerror = null;
    logger.info("app: starting server");

    const ready_callback: ?Server.ReadyCallback = if (cli.ready_fd != null) .{
        .context = &ready_pipe,
        .notify = ReadyPipe.notify,
    } else null;
    const received_signal = superviseServer(init.io, server, logger, ready_callback) catch |err| blk: {
        logger.err("app: server runtime failed", err, @errorReturnTrace());
        runtime_error = err;
        break :blk null;
    };
    _ = received_signal;

    var cleanup_error: ?anyerror = null;
    logger.info("app: cleaning up server");
    server.destroy() catch |err| {
        logger.err("app: server shutdown failed", err, @errorReturnTrace());
        cleanup_error = err;
    };

    if (runtime_error) |err| return err;
    if (cleanup_error) |err| return err;
    logger.info("app: server stopped");
}

// create tasks and listen on their cancellation
fn superviseServer(io: std.Io, server: *Server, logger: logging.Logger, ready_callback: ?Server.ReadyCallback) !?std.posix.SIG {
    var result_buffer: [2]RunOutcome = undefined;
    var select = std.Io.Select(RunOutcome).init(io, &result_buffer);

    try select.concurrent(.server, Server.run, .{ server, ready_callback });
    defer select.cancelDiscard();

    try select.concurrent(.shutdown_signal, waitForShutdownSignal, .{io});

    const first = try select.await();
    switch (first) {
        .shutdown_signal => |signal_result| {
            const signal = try signal_result;
            logger.info("app: stopping server");
            return signal;
        },
        .server => |server_result| {
            try server_result;
            return null;
        },
    }
}

fn waitForShutdownSignal(io: std.Io) std.Io.Cancelable!std.posix.SIG {
    try shutdown_event.wait(io);
    return @enumFromInt(shutdown_signal_number.load(.acquire));
}

fn shutdownHandler(signal: std.posix.SIG) callconv(.c) void {
    shutdown_signal_number.store(@intFromEnum(signal), .release);
    shutdown_event.set(shutdown_io);
}

test "application reports loader failures once with the source error" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "kgcache.conf" });
    defer testing.allocator.free(path);
    const path_arg = try testing.allocator.dupeZ(u8, path);
    defer testing.allocator.free(path_arg);
    const cases = [_]struct { contents: ?[]const u8, err: anyerror, fail_allocation: bool = false }{
        .{ .contents = null, .err = error.FileNotFound },
        .{ .contents = "port invalid", .err = error.InvalidValue },
        .{ .contents = "save 60 1\nsave 300 invalid", .err = error.InvalidValue },
        .{ .contents = "unknown value", .err = error.UnknownDirective },
        .{ .contents = "port", .err = error.MalformedLine },
        .{ .contents = "port 7000\nsave 60 1", .err = error.OutOfMemory, .fail_allocation = true },
    };
    for (cases) |case| {
        if (case.contents) |contents| {
            try tmp.dir.writeFile(testing.io, .{ .sub_path = "kgcache.conf", .data = contents });
        }
        var arena = std.heap.ArenaAllocator.init(if (case.fail_allocation) testing.failing_allocator else testing.allocator);
        defer arena.deinit();
        const args = [_][*:0]const u8{ "kgcache", path_arg.ptr, "--port", "8000" };
        const init: std.process.Init = .{
            .minimal = .{
                .args = .{ .vector = &args },
                .environ = std.process.Environ.empty,
            },
            .arena = &arena,
            .gpa = testing.allocator,
            .io = testing.io,
            .environ_map = undefined,
            .preopens = undefined,
        };
        var test_logger = logging.TestLogger.init();
        try testing.expectError(case.err, runApplication(init, test_logger.logger()));
        const events = test_logger.recordedEvents();
        try testing.expectEqual(1, events.len);
        try testing.expectEqual(logging.TestLogger.Event.Kind.err, events[0].kind);
        try testing.expectEqualStrings("app: failed to load configuration", events[0].message());
        try testing.expectEqual(case.err, events[0].source.?);
    }
}

test "application reports a CLI error once" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const args = [_][*:0]const u8{ "kgcache", "--ready-fd", "2" };
    const init: std.process.Init = .{
        .minimal = .{
            .args = .{ .vector = &args },
            .environ = std.process.Environ.empty,
        },
        .arena = &arena,
        .gpa = testing.allocator,
        .io = testing.io,
        .environ_map = undefined,
        .preopens = undefined,
    };
    var test_logger = logging.TestLogger.init();

    try testing.expectError(error.InvalidReadyFd, runApplication(init, test_logger.logger()));

    const events = test_logger.recordedEvents();
    try testing.expectEqual(1, events.len);
    try testing.expectEqualStrings("app: invalid command line", events[0].message());
    try testing.expectEqual(error.InvalidReadyFd, events[0].source.?);
}

test "application reports override errors before reading the config file" {
    const testing = std.testing;
    const cases = [_]struct { argv: []const [*:0]const u8, err: Cli.Error }{
        .{ .argv = &.{ "kgcache", "scratch-missing-config-for-cli-order-test.conf", "--port", "invalid", "--port", "7000" }, .err = error.InvalidValue },
        .{ .argv = &.{ "kgcache", "scratch-missing-config-for-cli-order-test.conf", "--port" }, .err = error.MissingValue },
        .{ .argv = &.{ "kgcache", "scratch-missing-config-for-cli-order-test.conf", "--save", "0", "1", "--save", "60", "1" }, .err = error.InvalidValue },
        .{ .argv = &.{ "kgcache", "--port", "7000", "--port", "invalid", "scratch-missing-config-for-cli-order-test.conf" }, .err = error.InvalidValue },
        .{ .argv = &.{ "kgcache", "scratch-missing-config-for-cli-order-test.conf", "--unknown" }, .err = error.UnknownFlag },
        .{ .argv = &.{ "kgcache", "scratch-missing-config-for-cli-order-test.conf", "--appendonly", "YES" }, .err = error.InvalidValue },
        .{ .argv = &.{ "kgcache", "scratch-missing-config-for-cli-order-test.conf", "--appendfsync", "invalid" }, .err = error.InvalidValue },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const init: std.process.Init = .{
            .minimal = .{
                .args = .{ .vector = case.argv },
                .environ = std.process.Environ.empty,
            },
            .arena = &arena,
            .gpa = testing.allocator,
            .io = testing.io,
            .environ_map = undefined,
            .preopens = undefined,
        };
        var test_logger = logging.TestLogger.init();
        try testing.expectError(case.err, runApplication(init, test_logger.logger()));
        const events = test_logger.recordedEvents();
        try testing.expectEqual(1, events.len);
        try testing.expectEqualStrings("app: invalid command line", events[0].message());
        try testing.expectEqual(case.err, events[0].source.?);
    }
}

test "shutdown handler wakes the signal waiter with the received signal" {
    shutdown_io = std.testing.io;
    shutdown_signal_number.store(0, .release);
    shutdown_event.reset();
    defer shutdown_event.reset();

    shutdownHandler(.TERM);

    try std.testing.expectEqual(std.posix.SIG.TERM, try waitForShutdownSignal(std.testing.io));
}
