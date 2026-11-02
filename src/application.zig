const std = @import("std");
const build_options = @import("build_options");
const Cli = @import("cli.zig");
const ConfigLoader = @import("config/loader.zig");
pub const Server = @import("server.zig");
const ReadyPipe = @import("readiness.zig");
pub const logging = @import("logger.zig");
const healthcheck = @import("healthcheck.zig");
const lifecycle = @import("lifecycle.zig");
pub const LifecycleHooks = lifecycle.LifecycleHooks;

// One-time setup before supervision. Failure triggers cleanup.
// Application owns Server. Keep context and dependencies alive through cleanup.
pub const ConfigureServer = struct {
    context: *anyopaque,
    configure: *const fn (*anyopaque, *Server) anyerror!void,
};

pub const Options = struct {
    lifecycle_hooks: ?LifecycleHooks = null,
    configure_server: ?ConfigureServer = null,
};

const LifecycleContext = struct {
    ready_pipe: ReadyPipe,
    caller_hooks: ?LifecycleHooks,

    fn lifecycleHooks(self: *LifecycleContext) ?LifecycleHooks {
        const has_ready = self.ready_pipe.file != null or
            (if (self.caller_hooks) |hooks| hooks.on_ready != null else false);
        const has_draining = if (self.caller_hooks) |hooks| hooks.on_persistence_draining != null else false;
        if (!has_ready and !has_draining) return null;

        return .{
            .context = self,
            .on_ready = if (has_ready) notifyReady else null,
            .on_persistence_draining = if (has_draining) notifyPersistenceDraining else null,
        };
    }

    fn notifyReady(context: *anyopaque, address: std.Io.net.IpAddress) anyerror!void {
        const self: *LifecycleContext = @ptrCast(@alignCast(context));
        if (self.caller_hooks) |hooks| try hooks.notifyReady(address);
        try ReadyPipe.notify(&self.ready_pipe, address);
    }

    fn notifyPersistenceDraining(context: *anyopaque) void {
        const self: *LifecycleContext = @ptrCast(@alignCast(context));
        if (self.caller_hooks) |hooks| hooks.notifyPersistenceDraining();
    }
};

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

pub fn run(init: std.process.Init, logger: logging.Logger, options: Options) !void {
    const mode = Cli.modeFromArgs(init.minimal.args);
    var cli = Cli.parse(init.arena, init.minimal.args) catch |err| {
        if (mode == .healthcheck) {
            logger.err("healthcheck: invalid command line", err, null);
        } else {
            logger.err("app: invalid command line", err, @errorReturnTrace());
        }
        return err;
    };
    defer cli.deinit();

    if (cli.mode == .version) {
        try std.Io.File.writeStreamingAll(std.Io.File.stdout(), init.io, "kgcache " ++ build_options.version ++ "\n");
        return;
    }

    // CLI and file loading share this borrowed arena.
    // Zig releases it after the application returns.
    const config = ConfigLoader.load(
        init.io,
        init.arena,
        cli.config_path,
        cli.overrides.items,
    ) catch |err| {
        if (mode == .healthcheck) {
            logger.err("healthcheck: invalid configuration", err, null);
        } else {
            logger.err("app: failed to load configuration", err, @errorReturnTrace());
        }
        return err;
    };

    if (cli.mode == .healthcheck) {
        healthcheck.probe(init.io, config) catch |err| {
            logger.err(healthcheck.diagnostic(err), err, null);
            return err;
        };
        return;
    }

    var lifecycle_context: LifecycleContext = .{
        .ready_pipe = ReadyPipe.init(init.io, cli.ready_fd),
        .caller_hooks = options.lifecycle_hooks,
    };
    defer lifecycle_context.ready_pipe.close();

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    const shutdown_handlers = ShutdownHandlers.install(init.io);
    defer shutdown_handlers.restore();

    const server = Server.create(init.io, gpa.allocator(), config, logger, .{
        .lifecycle_hooks = lifecycle_context.lifecycleHooks(),
    }) catch |err| {
        logger.err("app: failed to create server", err, @errorReturnTrace());
        return err;
    };

    var application_error: ?anyerror = null;
    if (options.configure_server) |setup| {
        setup.configure(setup.context, server) catch |err| {
            logger.err("app: failed to configure server", err, @errorReturnTrace());
            application_error = err;
        };
    }

    var received_signal: ?std.posix.SIG = null;
    if (application_error == null) {
        logger.info("app: starting server");

        // this is blocking and will only return either 1. Server run return / crash , 2. receives SIGINT/SIGTERM
        received_signal = superviseServer(init.io, server, logger) catch |err| blk: {
            logger.err("app: server runtime failed", err, @errorReturnTrace());
            application_error = err;
            break :blk null;
        };
    }

    const stop_reason: Server.StopReason = if (received_signal) |signal| switch (signal) {
        .INT, .TERM => .clean_signal,
        else => .cleanup,
    } else .cleanup;

    var cleanup_error: ?anyerror = null;
    logger.info("app: cleaning up server");
    server.destroy(stop_reason) catch |err| {
        logger.err("app: server shutdown failed", err, @errorReturnTrace());
        cleanup_error = err;
    };

    if (application_error) |err| return err;
    if (cleanup_error) |err| return err;
    logger.info("app: server stopped");
}

// create tasks and listen on their cancellation
fn superviseServer(io: std.Io, server: *Server, logger: logging.Logger) !?std.posix.SIG {
    var result_buffer: [2]RunOutcome = undefined;
    var select = std.Io.Select(RunOutcome).init(io, &result_buffer);

    try select.concurrent(.server, Server.run, .{server});
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
    const cases = [_]struct { contents: ?[]const u8, err: anyerror }{
        .{ .contents = null, .err = error.FileNotFound },
        .{ .contents = "port invalid", .err = error.InvalidValue },
        .{ .contents = "save 60 1\nsave 300 invalid", .err = error.InvalidValue },
        .{ .contents = "port \"invalid\"\nport \"7000\"", .err = error.InvalidValue },
        .{ .contents = "port \"7000\" trailing", .err = error.MalformedLine },
        .{ .contents = "dir \"bad\\q\"", .err = error.MalformedLine },
        .{ .contents = "dir \"\"", .err = error.InvalidValue },
        .{ .contents = "save \"60\" \"1\"\nsave \"0\" \"1\"\nsave \"\"", .err = error.InvalidValue },
        .{ .contents = "unknown value", .err = error.UnknownDirective },
        .{ .contents = "port", .err = error.MalformedLine },
    };
    for (cases) |case| {
        if (case.contents) |contents| {
            try tmp.dir.writeFile(testing.io, .{ .sub_path = "kgcache.conf", .data = contents });
        }
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
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
        try testing.expectError(case.err, run(init, test_logger.logger(), .{}));
        const events = test_logger.recordedEvents();
        try testing.expectEqual(1, events.len);
        try testing.expectEqual(logging.TestLogger.Event.Kind.err, events[0].kind);
        try testing.expectEqualStrings("app: failed to load configuration", events[0].message());
        try testing.expectEqual(case.err, events[0].source.?);
    }
}

test "application reports CLI errors once" {
    const testing = std.testing;
    const cases = [_]struct { argv: []const [*:0]const u8, err: Cli.Error, fail_allocation: bool = false }{
        .{ .argv = &.{ "kgcache", "--ready-fd", "2" }, .err = error.InvalidReadyFd },
        .{ .argv = &.{ "kgcache", "--port", "7000" }, .err = error.OutOfMemory, .fail_allocation = true },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(if (case.fail_allocation) testing.failing_allocator else testing.allocator);
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
        try testing.expectError(case.err, run(init, test_logger.logger(), .{}));

        const events = test_logger.recordedEvents();
        try testing.expectEqual(1, events.len);
        try testing.expectEqualStrings("app: invalid command line", events[0].message());
        try testing.expectEqual(case.err, events[0].source.?);
    }
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
        try testing.expectError(case.err, run(init, test_logger.logger(), .{}));
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

test "caller readiness failure prevents READY output" {
    const testing = std.testing;
    const Caller = struct {
        called: bool = false,

        fn ready(context: *anyopaque, _: std.Io.net.IpAddress) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.called = true;
            return error.TestReadyFailure;
        }
    };
    var fds: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.PipeFailed;
    defer _ = std.c.close(fds[0]);

    var caller: Caller = .{};
    var context: LifecycleContext = .{
        .ready_pipe = ReadyPipe.init(testing.io, fds[1]),
        .caller_hooks = .{
            .context = &caller,
            .on_ready = Caller.ready,
        },
    };
    defer context.ready_pipe.close();
    const hooks = context.lifecycleHooks().?;
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(4321) };
    try testing.expectError(error.TestReadyFailure, hooks.notifyReady(address));
    try testing.expect(caller.called);
    try testing.expect(context.ready_pipe.file != null);

    context.ready_pipe.close();
    var buffer: [64]u8 = undefined;
    try testing.expectEqual(@as(isize, 0), std.c.read(fds[0], &buffer, buffer.len));
}

test "application setup failure skips readiness and cleans up with the caller context" {
    const testing = std.testing;
    const Context = struct {
        configure_count: usize = 0,
        ready_count: usize = 0,
        drain_count: usize = 0,
        server_graph_ready: bool = false,
        cleanup_saw_setup: bool = false,

        fn configure(context: *anyopaque, server: *Server) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.configure_count += 1;
            self.server_graph_ready = server._data_storages.len > 0 and server._cron_thread == null;
            return error.TestSetupFailure;
        }

        fn ready(context: *anyopaque, _: std.Io.net.IpAddress) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.ready_count += 1;
        }

        fn draining(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.drain_count += 1;
            self.cleanup_saw_setup = self.configure_count == 1;
        }
    };
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer testing.allocator.free(dir);
    const dir_arg = try testing.allocator.dupeZ(u8, dir);
    defer testing.allocator.free(dir_arg);
    var fds: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.PipeFailed;
    defer _ = std.c.close(fds[0]);
    var fd_buffer: [16]u8 = undefined;
    const fd_arg = try std.fmt.bufPrintZ(&fd_buffer, "{d}", .{fds[1]});
    const args = [_][*:0]const u8{ "kgcache", "--dir", dir_arg.ptr, "--ready-fd", fd_arg.ptr };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
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
    var context: Context = .{};
    var test_logger = logging.TestLogger.init();
    try testing.expectError(error.TestSetupFailure, run(init, test_logger.logger(), .{
        .lifecycle_hooks = .{
            .context = &context,
            .on_ready = Context.ready,
            .on_persistence_draining = Context.draining,
        },
        .configure_server = .{ .context = &context, .configure = Context.configure },
    }));
    try testing.expectEqual(@as(usize, 1), context.configure_count);
    try testing.expectEqual(@as(usize, 0), context.ready_count);
    try testing.expectEqual(@as(usize, 1), context.drain_count);
    try testing.expect(context.server_graph_ready);
    try testing.expect(context.cleanup_saw_setup);
    try testing.expectEqual(@as(c_int, -1), std.c.fcntl(fds[1], std.posix.F.GETFD));
    var byte: [1]u8 = undefined;
    try testing.expectEqual(@as(isize, 0), std.c.read(fds[0], &byte, 1));

    var errors: usize = 0;
    for (test_logger.recordedEvents()) |event| {
        if (event.kind != .err) continue;
        errors += 1;
        try testing.expectEqualStrings("app: failed to configure server", event.message());
        try testing.expectEqual(error.TestSetupFailure, event.source.?);
    }
    try testing.expectEqual(@as(usize, 1), errors);
}

test "readiness failures return their source after stopping cron and cleaning up" {
    const testing = std.testing;
    const Context = struct {
        server: ?*Server = null,
        fail_ready: bool,
        ready_count: usize = 0,
        drain_count: usize = 0,
        selected_port: u16 = 0,
        listener_fd: ?std.posix.fd_t = null,
        cron_was_running: bool = false,
        cleanup_was_safe: bool = false,

        fn configure(ptr: *anyopaque, server: *Server) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.server = server;
        }

        fn ready(ptr: *anyopaque, address: std.Io.net.IpAddress) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const server = self.server.?;
            self.ready_count += 1;
            self.selected_port = address.getPort();
            self.listener_fd = server._listener.?.socket.handle;
            self.cron_was_running = server._cron_thread != null;
            try testing.expectEqual(server._listener.?.socket.address, address);
            try testing.expectEqual([4]u8{ 127, 0, 0, 1 }, address.ip4.bytes);
            if (self.fail_ready) return error.TestReadyFailure;
        }

        fn draining(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.drain_count += 1;
            const server = self.server.?;
            self.cleanup_was_safe = server._cron_thread == null and server._data_storages.len == 1;
        }
    };
    for ([_]enum { caller, pipe, bind_address }{ .caller, .pipe, .bind_address }) |failure| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        const dir_arg = try std.fmt.allocPrintSentinel(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path}, 0);
        defer testing.allocator.free(dir_arg);
        var fds: [2]std.posix.fd_t = undefined;
        if (std.c.pipe(&fds) != 0) return error.PipeFailed;
        // Passing the read end makes the actual readiness write fail.
        const ready_fd = if (failure == .pipe) fds[0] else fds[1];
        const retained_fd = if (failure == .pipe) fds[1] else fds[0];
        defer _ = std.c.close(retained_fd);
        var fd_buffer: [16]u8 = undefined;
        const fd_arg = try std.fmt.bufPrintZ(&fd_buffer, "{d}", .{ready_fd});
        const occupied_address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        var occupied = try occupied_address.listen(testing.io, .{});
        defer occupied.deinit(testing.io);
        var port_buffer: [8]u8 = undefined;
        const port_arg = try std.fmt.bufPrintZ(&port_buffer, "{d}", .{if (failure == .bind_address) occupied.socket.address.getPort() else @as(u16, 0)});
        const args = [_][*:0]const u8{
            "kgcache", "--dir", dir_arg.ptr, "--port", port_arg.ptr, "--reuse-address", "no", "--databases", "1", "--ready-fd", fd_arg.ptr,
        };
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const init: std.process.Init = .{
            .minimal = .{ .args = .{ .vector = &args }, .environ = std.process.Environ.empty },
            .arena = &arena,
            .gpa = testing.allocator,
            .io = testing.io,
            .environ_map = undefined,
            .preopens = undefined,
        };
        var context: Context = .{ .fail_ready = failure == .caller };
        var logger = logging.TestLogger.init();
        const expected: anyerror = switch (failure) {
            .caller => error.TestReadyFailure,
            .pipe => error.NotOpenForWriting,
            .bind_address => error.AddressInUse,
        };
        try testing.expectError(expected, run(init, logger.logger(), .{
            .configure_server = .{ .context = &context, .configure = Context.configure },
            .lifecycle_hooks = .{ .context = &context, .on_ready = Context.ready, .on_persistence_draining = Context.draining },
        }));
        try testing.expectEqual(@as(usize, if (failure == .bind_address) 0 else 1), context.ready_count);
        try testing.expectEqual(@as(usize, 1), context.drain_count);
        try testing.expect(context.cleanup_was_safe);
        if (failure != .bind_address) {
            try testing.expect(context.selected_port != 0);
            try testing.expect(context.cron_was_running);
            try testing.expectEqual(@as(c_int, -1), std.c.fcntl(context.listener_fd.?, std.posix.F.GETFD));
        }
        try testing.expectEqual(@as(c_int, -1), std.c.fcntl(ready_fd, std.posix.F.GETFD));
        if (failure != .pipe) {
            var byte: [1]u8 = undefined;
            try testing.expectEqual(@as(isize, 0), std.c.read(retained_fd, &byte, 1));
        }
        var reports: usize = 0;
        for (logger.recordedEvents()) |event| {
            if (event.kind != .err) continue;
            reports += 1;
            try testing.expectEqual(expected, event.source.?);
            try testing.expectEqualStrings("app: server runtime failed", event.message());
        }
        try testing.expectEqual(@as(usize, 1), reports);
    }
}
