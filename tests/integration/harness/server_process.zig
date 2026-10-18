const std = @import("std");
pub const control_protocol = @import("persistence_test_protocol");
const failure_artifacts = @import("failure_artifacts.zig");

const log_limit = 16 * 1024;

pub const Options = struct {
    case_name: []const u8 = "process fixture",
    startup_timeout_ms: i64 = 5_000,
    read_timeout_ms: i64 = 3_000,
    stop_timeout_ms: i64 = 5_000,
    /// Config path relative to the fixture's working directory, or null for CLI-only startup.
    config_subpath: ?[]const u8 = "kgcache.conf",
    /// Number of extra_args before the config path. Use extra_args.len to place it last.
    config_arg_index: usize = 0,
    extra_config: []const u8 = "",
    /// Borrowed CLI arguments. Keep their storage alive through the fixture's lifetime.
    extra_args: []const []const u8 = &.{},
    /// Disable when extra_args supplies readiness arguments for a rejected startup.
    auto_ready_fd: bool = true,
    artifact_dir: ?[]const u8 = null,
    report_failures: bool = true,
    control_child: ?control_protocol.Backend = null,
    control_stage: control_protocol.Stage = .synced,
};

pub const ServerProcess = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    executable_path: []const u8,
    options: Options,
    data_dir: []const u8,
    config_path: ?[]const u8,
    config: ?[]const u8 = null,
    address: ?std.Io.net.IpAddress = null,
    pid: ?std.posix.pid_t = null,
    last_exit_status: ?u32 = null,
    ready_bytes_read: usize = 0,
    drainer: ?std.Thread = null,
    stdout: Log = .{},
    stderr: Log = .{},
    failed: bool = false,
    failure_reported: bool = false,
    ready_buffer: [128]u8 = undefined,
    control_events: ?std.posix.fd_t = null,
    control_release: ?std.posix.fd_t = null,
    last_control_event: ?control_protocol.Event = null,
    run_number: usize = 0,
    phase: []const u8 = "created",
    failure_error: ?anyerror = null,
    failure_saved: bool = false,
    ready_ok: bool = false,
    last_signal: ?std.posix.SIG = null,
    forced_kill: bool = false,

    pub fn create(io: std.Io, allocator: std.mem.Allocator, executable_path: []const u8, options: Options) !*ServerProcess {
        const self = try createStopped(io, allocator, executable_path, options);
        errdefer self.destroy();
        try self.start();
        return self;
    }

    pub fn createStopped(io: std.Io, allocator: std.mem.Allocator, executable_path: []const u8, options: Options) !*ServerProcess {
        if (options.config_subpath != null and options.config_arg_index > options.extra_args.len) return error.InvalidConfigArgumentIndex;
        var random_bytes: [12]u8 = undefined;
        std.Io.random(io, &random_bytes);
        const suffix = std.fmt.bytesToHex(random_bytes, .lower);
        const data_dir = try std.fmt.allocPrint(allocator, "/tmp/kgcache-integration-{s}", .{suffix});
        var paths_owned_by_self = false;
        errdefer if (!paths_owned_by_self) allocator.free(data_dir);

        const config_path: ?[]const u8 = if (options.config_subpath) |subpath|
            try std.fs.path.join(allocator, &.{ data_dir, subpath })
        else
            null;
        errdefer if (!paths_owned_by_self) {
            if (config_path) |path| allocator.free(path);
        };

        const cwd = std.Io.Dir.cwd();
        try cwd.createDir(io, data_dir, .default_dir);

        var directory_owned = true;
        errdefer if (directory_owned) cwd.deleteTree(io, data_dir) catch {};

        if (config_path) |path| try cwd.createDirPath(io, std.fs.path.dirname(path).?);

        const self = try allocator.create(ServerProcess);
        self.* = .{
            .io = io,
            .allocator = allocator,
            .executable_path = executable_path,
            .options = options,
            .data_dir = data_dir,
            .config_path = config_path,
        };
        paths_owned_by_self = true;
        directory_owned = false;
        return self;
    }

    pub fn start(self: *ServerProcess) !void {
        if (self.pid != null) return error.AlreadyRunning;
        if (self.options.config_subpath != null and self.options.config_arg_index > self.options.extra_args.len) return error.InvalidConfigArgumentIndex;
        if (self.failed) self.saveFailure();
        self.run_number += 1;
        self.phase = "startup";
        self.failure_error = null;
        self.failure_saved = false;
        self.ready_ok = false;
        self.last_signal = null;
        self.forced_kill = false;
        self.failure_reported = false;
        self.last_exit_status = null;
        self.ready_bytes_read = 0;
        self.closeControl();
        self.last_control_event = null;

        var control_env = std.process.Environ.Map.init(self.allocator);
        defer control_env.deinit();
        var inherited_events: ?std.posix.fd_t = null;
        defer {
            if (inherited_events) |fd| _ = std.c.close(fd);
        }
        var inherited_release: ?std.posix.fd_t = null;
        defer {
            if (inherited_release) |fd| _ = std.c.close(fd);
        }
        if (self.options.control_child) |backend| {
            var events: [2]std.posix.fd_t = undefined;
            if (std.c.pipe(&events) != 0) return error.PipeFailed;
            self.control_events = events[0];
            inherited_events = events[1];
            var release: [2]std.posix.fd_t = undefined;
            if (std.c.pipe(&release) != 0) return error.PipeFailed;
            inherited_release = release[0];
            self.control_release = release[1];
            if (std.c.fcntl(events[0], std.posix.F.SETFD, @as(c_int, std.posix.FD_CLOEXEC)) != 0) return error.FcntlFailed;
            if (std.c.fcntl(release[1], std.posix.F.SETFD, @as(c_int, std.posix.FD_CLOEXEC)) != 0) return error.FcntlFailed;
            const setting = try std.fmt.allocPrint(self.allocator, "{d} {d} {s} {s}", .{ events[1], release[0], @tagName(backend), @tagName(self.options.control_stage) });
            defer self.allocator.free(setting);
            try control_env.put("KGCACHE_TEST_CONTROL", setting);
        }

        const port: u16 = if (self.address) |address| address.getPort() else 0;
        if (self.config_path) |path| {
            const config = try std.fmt.allocPrint(
                self.allocator,
                "bind 127.0.0.1\nport {d}\nreuse-address yes\ncron-interval-ms 20\nappenddirname aof\nappendfilename appendonly.aof\n{s}",
                .{ port, self.options.extra_config },
            );

            if (self.config) |old| self.allocator.free(old);
            self.config = config;

            try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = config });
        }

        var ready_fds: [2]std.posix.fd_t = undefined;
        if (std.c.pipe(&ready_fds) != 0) return error.PipeFailed;
        defer _ = std.c.close(ready_fds[0]);

        var writer_open = true;
        defer if (writer_open) {
            _ = std.c.close(ready_fds[1]);
        };

        var fd_buffer: [16]u8 = undefined;
        const ready_fd_arg = try std.fmt.bufPrint(&fd_buffer, "{d}", .{ready_fds[1]});
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.allocator);
        try argv.append(self.allocator, self.executable_path);
        const config_arg_index = if (self.options.config_subpath != null) self.options.config_arg_index else 0;
        try argv.appendSlice(self.allocator, self.options.extra_args[0..config_arg_index]);
        if (self.options.config_subpath) |subpath| try argv.append(self.allocator, subpath);
        if (self.options.auto_ready_fd) try argv.appendSlice(self.allocator, &.{ "--ready-fd", ready_fd_arg });
        try argv.appendSlice(self.allocator, self.options.extra_args[config_arg_index..]);
        var port_buffer: [5]u8 = undefined;
        if (port != 0) {
            const port_arg = try std.fmt.bufPrint(&port_buffer, "{d}", .{port});
            try argv.appendSlice(self.allocator, &.{ "--port", port_arg });
        }
        var child = try std.process.spawn(self.io, .{
            .argv = argv.items,
            .cwd = .{ .path = self.data_dir },
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
            .environ_map = if (self.options.control_child != null) &control_env else null,
        });
        self.pid = child.id.?;
        _ = std.c.close(ready_fds[1]);
        writer_open = false;

        self.stdout = .{ .fd = child.stdout.?.handle };
        self.stderr = .{ .fd = child.stderr.?.handle };
        child.stdout = null;
        child.stderr = null;
        self.drainer = std.Thread.spawn(.{}, drainLogs, .{self}) catch |err| {
            self.failed = true;
            self.forceKill();
            self.stdout.close();
            self.stderr.close();
            return err;
        };

        const line = self.readReady(ready_fds[0]) catch |err| {
            self.failed = true;
            self.forceKill();
            self.joinDrainer();
            self.report("startup", err);
            return err;
        };

        const selected = parseReady(line) catch |err| {
            self.failed = true;
            self.forceKill();
            self.joinDrainer();
            self.report("READY", err);
            return err;
        };

        if (port != 0 and selected.getPort() != port) {
            self.failed = true;
            self.forceKill();
            self.joinDrainer();
            self.report("restart port", error.WrongReadyPort);
            return error.WrongReadyPort;
        }

        const early_exit = self.pollExit() catch |err| {
            self.failed = true;
            self.forceKill();
            self.joinDrainer();
            self.report("startup", err);
            return err;
        };

        if (early_exit != null) {
            self.failed = true;
            self.joinDrainer();
            self.report("startup", error.StartupExited);
            return error.StartupExited;
        }
        self.address = selected;
        self.ready_ok = true;
        self.phase = "RESP checks";
    }

    pub fn stop(self: *ServerProcess) !void {
        return self.stopWithSignal(.TERM);
    }

    pub fn stopWithSignal(self: *ServerProcess, signal: std.posix.SIG) !void {
        return self.stopExpectingExit(signal, 0);
    }

    pub fn stopExpectingExit(self: *ServerProcess, signal: std.posix.SIG, expected_code: u8) !void {
        self.sendSignal(signal) catch |err| switch (err) {
            error.ProcessNotFound => {},
            else => {
                self.failed = true;
                self.forceKill();
                self.joinDrainer();
                self.report("shutdown", err);
                return err;
            },
        };
        try self.waitForExit(expected_code);
    }

    pub fn sendSignal(self: *ServerProcess, signal: std.posix.SIG) !void {
        const pid = self.pid orelse return error.NotRunning;
        self.phase = "shutdown";
        self.last_signal = signal;
        try std.posix.kill(pid, signal);
    }

    pub fn waitForExit(self: *ServerProcess, expected_code: u8) !void {
        const deadline = now(self.io) + self.options.stop_timeout_ms;
        while (self.pid != null) {
            const status = self.pollExit() catch |err| {
                self.failed = true;
                self.forceKill();
                self.joinDrainer();
                self.report("shutdown", err);
                return err;
            };
            if (status) |code| {
                self.joinDrainer();
                if (!std.c.W.IFEXITED(code) or std.c.W.EXITSTATUS(code) != expected_code) {
                    self.failed = true;
                    self.report("shutdown", error.UncleanShutdown);
                    return error.UncleanShutdown;
                }
                self.phase = "after shutdown checks";
                return;
            }
            if (now(self.io) >= deadline) {
                self.failed = true;
                self.forceKill();
                self.joinDrainer();
                self.report("shutdown", error.ShutdownTimeout);
                return error.ShutdownTimeout;
            }
            var empty: [0]std.posix.pollfd = .{};
            _ = std.posix.poll(&empty, 10) catch |err| {
                self.failed = true;
                self.forceKill();
                self.joinDrainer();
                self.report("shutdown", err);
                return err;
            };
        }
    }

    pub fn waitForControl(self: *ServerProcess, stage: control_protocol.Stage) !control_protocol.Event {
        self.phase = "child control";
        var event: control_protocol.Event = undefined;
        self.readExact(self.control_events orelse return error.MissingChildControl, std.mem.asBytes(&event)) catch |err| {
            self.report("child control", err);
            return err;
        };
        const previous_event = self.last_control_event;
        self.last_control_event = event;
        if (event.server_pid != self.pid or event.operation != 1 or event.stage != stage) return error.UnexpectedChildStage;
        if (event.backend != self.options.control_child) return error.WrongControlledBackend;
        if (previous_event) |previous| {
            if (event.child_pid != previous.child_pid or event.backend != previous.backend) return error.WrongControlledChild;
        }
        return event;
    }

    pub fn releaseChild(self: *ServerProcess) !void {
        try self.sendChildCommand('r');
    }

    pub fn failChildWrite(self: *ServerProcess) !void {
        try self.sendChildCommand('f');
    }

    fn sendChildCommand(self: *ServerProcess, command: u8) !void {
        if (try self.pollExit() != null) return error.ServerExitedBeforeChildRelease;
        const fd = self.control_release orelse return error.MissingChildControl;
        while (true) {
            const n = std.c.write(fd, @ptrCast(&command), 1);
            if (n < 0 and std.posix.errno(n) == .INTR) continue;
            if (n != 1) return error.ChildReleaseFailed;
            return;
        }
    }

    fn closeControl(self: *ServerProcess) void {
        if (self.control_release) |fd| _ = std.c.close(fd);
        if (self.control_events) |fd| _ = std.c.close(fd);
        self.control_release = null;
        self.control_events = null;
    }

    pub fn restart(self: *ServerProcess) !void {
        if (self.pid != null) try self.stop();
        try self.start();
    }

    pub fn readExact(self: *ServerProcess, fd: std.posix.fd_t, buffer: []u8) !void {
        const deadline = now(self.io) + self.options.read_timeout_ms;
        var used: usize = 0;
        while (used < buffer.len) {
            var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};

            const remaining = deadline - now(self.io);
            if (remaining <= 0) return error.ProtocolReadTimeout;

            // wait for n ms where remaining 100ms < n < remaining
            if (try std.posix.poll(&fds, @intCast(@min(remaining, 100))) == 0) continue;
            const n = try std.posix.read(fd, buffer[used..]);
            if (n == 0) return error.PrematureReplyEnd;
            used += n;
        }
    }

    pub fn destroy(self: *ServerProcess) void {
        if (self.pid != null and self.control_release != null) {
            self.failed = true;
            // Let the server reap a held child before forcing parent cleanup.
            _ = std.c.close(self.control_release.?);
            self.control_release = null;
            self.stop() catch {};
        }
        self.closeControl();
        if (self.pid != null) {
            self.failed = true;
            self.forceKill();
        }
        self.joinDrainer();

        if (self.failed) {
            if (self.options.report_failures and !self.failure_reported) {
                std.log.err("integration: fixture failed; stdout: {s}; stderr: {s}", .{
                    self.stdout.bytes(), self.stderr.bytes(),
                });
            }
            self.saveFailure();
        }

        std.Io.Dir.cwd().deleteTree(self.io, self.data_dir) catch |err| {
            std.log.err("integration: cannot remove fixture {s}: {s}", .{ self.data_dir, @errorName(err) });
        };
        if (self.config) |config| self.allocator.free(config);
        if (self.config_path) |path| self.allocator.free(path);
        self.allocator.free(self.data_dir);
        self.allocator.destroy(self);
    }

    fn readReady(self: *ServerProcess, fd: std.posix.fd_t) ![]const u8 {
        const deadline = now(self.io) + self.options.startup_timeout_ms;
        var used: usize = 0;
        while (used < self.ready_buffer.len) {
            var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
            const remaining = deadline - now(self.io);
            if (remaining <= 0) return error.StartupTimeout;
            if (try std.posix.poll(&fds, @intCast(@min(remaining, 100))) == 0) continue;
            const n = try std.posix.read(fd, self.ready_buffer[used..]);
            if (n == 0) {
                if (used != 0) return error.IncompleteReady;
                const exit_deadline = @min(deadline, now(self.io) + 100);
                while (true) {
                    if (try self.pollExit() != null) return error.StartupExited;
                    if (now(self.io) >= exit_deadline) break;
                    var empty: [0]std.posix.pollfd = .{};
                    _ = try std.posix.poll(&empty, 10);
                }
                return error.EmptyReady;
            }
            used += n;
            self.ready_bytes_read += n;
            if (std.mem.indexOfScalar(u8, self.ready_buffer[0..used], '\n')) |end| return self.ready_buffer[0 .. end + 1];
        }
        return error.ReadyTooLong;
    }

    fn pollExit(self: *ServerProcess) !?u32 {
        const pid = self.pid orelse return null;
        var status: c_int = 0;
        var result: std.posix.pid_t = undefined;
        while (true) {
            result = std.c.waitpid(pid, &status, std.c.W.NOHANG);
            if (result != -1 or std.posix.errno(result) != .INTR) break;
        }
        if (result == 0) return null;
        if (result == pid) {
            self.pid = null;
            self.last_exit_status = @bitCast(status);
            return self.last_exit_status;
        }
        return error.WaitFailed;
    }

    fn forceKill(self: *ServerProcess) void {
        const pid = self.pid orelse return;
        self.forced_kill = true;
        std.posix.kill(pid, .KILL) catch {};
        var status: c_int = 0;
        while (true) {
            const result = std.c.waitpid(pid, &status, 0);
            if (result == pid) break;
            if (std.posix.errno(result) != .INTR) {
                std.debug.panic("integration: waitpid failed while reaping child {d}", .{pid});
            }
        }
        self.last_exit_status = @bitCast(status);
        self.pid = null;
    }

    fn joinDrainer(self: *ServerProcess) void {
        if (self.drainer) |thread| {
            thread.join();
            self.drainer = null;
        }
    }

    fn report(self: *ServerProcess, phase: []const u8, err: anyerror) void {
        self.phase = phase;
        self.failure_error = err;
        if (!self.options.report_failures) return;
        self.failure_reported = true;
        std.log.err("integration: {s} failed: {s}; stdout: {s}; stderr: {s}", .{
            phase, @errorName(err), self.stdout.bytes(), self.stderr.bytes(),
        });
    }

    fn saveFailure(self: *ServerProcess) void {
        if (self.options.artifact_dir == null or self.failure_saved) return;
        self.captureFailure() catch |err| {
            std.log.err("integration: cannot capture failure artifacts: {s}", .{@errorName(err)});
            return;
        };
        self.failure_saved = true;
    }

    fn captureFailure(self: *ServerProcess) !void {
        const parent = self.options.artifact_dir.?;
        const name = std.fs.path.basename(self.data_dir);
        const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}-run-{d}", .{ parent, name, self.run_number });
        defer self.allocator.free(path);
        const cwd = std.Io.Dir.cwd();
        try cwd.createDirPath(self.io, path);
        const dir = try cwd.openDir(self.io, path, .{});
        defer dir.close(self.io);
        const config = self.config orelse "";
        try dir.writeFile(self.io, .{ .sub_path = "kgcache.conf", .data = config[0..@min(config.len, log_limit)] });
        try dir.writeFile(self.io, .{ .sub_path = "stdout.log", .data = self.stdout.bytes() });
        try dir.writeFile(self.io, .{ .sub_path = "stderr.log", .data = self.stderr.bytes() });
        try dir.writeFile(self.io, .{ .sub_path = "ready.txt", .data = self.ready_buffer[0..self.ready_bytes_read] });
        var status_buffer: [2048]u8 = undefined;
        var status = std.Io.Writer.fixed(&status_buffer);
        const exit_code: ?u8 = if (self.last_exit_status) |bits| (if (std.c.W.IFEXITED(bits)) @intCast(std.c.W.EXITSTATUS(bits)) else null) else null;
        const exit_signal: ?u32 = if (self.last_exit_status) |bits| (if (std.c.W.IFSIGNALED(bits)) @intFromEnum(std.c.W.TERMSIG(bits)) else null) else null;
        try status.print("case={s}\nrun={d}\nphase={s}\nerror={s}\nready={any}\nexit_status={?d}\nexit_code={?d}\nexit_signal={?d}\nrequested_signal={?d}\nforced_kill={any}\nconfig_truncated={any}\nstdout_truncated={any}\nstderr_truncated={any}\n", .{
            self.options.case_name[0..@min(self.options.case_name.len, 128)],
            self.run_number,
            self.phase,
            if (self.failure_error) |err| @errorName(err) else "none",
            self.ready_ok,
            self.last_exit_status,
            exit_code,
            exit_signal,
            if (self.last_signal) |signal| @as(?u32, @intFromEnum(signal)) else null,
            self.forced_kill,
            config.len > log_limit,
            self.stdout.truncated,
            self.stderr.truncated,
        });
        if (self.last_control_event) |event| {
            try status.print("server_pid={d}\nchild_pid={d}\noperation={d}\nbackend={s}\nchild_stage={s}\nchild_status={d}\n", .{
                event.server_pid, event.child_pid, event.operation, @tagName(event.backend), @tagName(event.stage), event.status,
            });
        }
        try dir.writeFile(self.io, .{ .sub_path = "status.txt", .data = status.buffered() });
        try failure_artifacts.copyFiles(self.io, self.allocator, self.data_dir, dir);
        if (self.options.report_failures) std.log.info("integration: failure artifacts: {s}", .{path});
    }
};

const Log = struct {
    fd: ?std.posix.fd_t = null,
    buffer: [log_limit]u8 = undefined,
    len: usize = 0,
    truncated: bool = false,

    pub fn bytes(self: *const Log) []const u8 {
        return self.buffer[0..self.len];
    }

    fn close(self: *Log) void {
        if (self.fd) |fd| _ = std.c.close(fd);
        self.fd = null;
    }

    fn drain(self: *Log) void {
        const fd = self.fd orelse return;
        var buffer: [4096]u8 = undefined;
        const n = std.posix.read(fd, &buffer) catch {
            self.close();
            return;
        };
        if (n == 0) {
            self.close();
            return;
        }
        const copy_len = @min(n, log_limit - self.len);
        @memcpy(self.buffer[self.len..][0..copy_len], buffer[0..copy_len]);
        self.len += copy_len;
        if (copy_len < n) self.truncated = true;
    }
};

fn drainLogs(self: *ServerProcess) void {
    while (self.stdout.fd != null or self.stderr.fd != null) {
        var fds = [_]std.posix.pollfd{
            .{ .fd = self.stdout.fd orelse -1, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = self.stderr.fd orelse -1, .events = std.posix.POLL.IN, .revents = 0 },
        };
        _ = std.posix.poll(&fds, -1) catch break;
        if (fds[0].revents != 0) self.stdout.drain();
        if (fds[1].revents != 0) self.stderr.drain();
    }
    self.stdout.close();
    self.stderr.close();
}

fn now(io: std.Io) i64 {
    return std.Io.Clock.awake.now(io).toMilliseconds();
}

fn parseReady(line: []const u8) !std.Io.net.IpAddress {
    if (!std.mem.startsWith(u8, line, "READY ") or line[line.len - 1] != '\n') return error.MalformedReady;
    const payload = line[6 .. line.len - 1];
    const separator = std.mem.lastIndexOfScalar(u8, payload, ' ') orelse return error.MalformedReady;
    const host = payload[0..separator];
    if (!std.mem.eql(u8, host, "127.0.0.1")) return error.WrongReadyAddress;
    const port = std.fmt.parseInt(u16, payload[separator + 1 ..], 10) catch return error.MalformedReady;
    if (port == 0) return error.ZeroReadyPort;
    return std.Io.net.IpAddress.parseIp4(host, port);
}
