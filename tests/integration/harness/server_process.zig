const std = @import("std");

const log_limit = 16 * 1024;

pub const Options = struct {
    startup_timeout_ms: i64 = 5_000,
    read_timeout_ms: i64 = 3_000,
    stop_timeout_ms: i64 = 5_000,
    extra_config: []const u8 = "",
    artifact_dir: ?[]const u8 = null,
    report_failures: bool = true,
};

pub const ServerProcess = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    executable_path: []const u8,
    options: Options,
    data_dir: []const u8,
    config_path: []const u8,
    config: ?[]const u8 = null,
    address: ?std.Io.net.IpAddress = null,
    pid: ?std.posix.pid_t = null,
    last_exit_status: ?u32 = null,
    ready_bytes_read: usize = 0,
    drainer: ?std.Thread = null,
    stdout: Log = .{},
    stderr: Log = .{},
    failed: bool = false,
    ready_buffer: [128]u8 = undefined,

    pub fn create(io: std.Io, allocator: std.mem.Allocator, executable_path: []const u8, options: Options) !*ServerProcess {
        const self = try createStopped(io, allocator, executable_path, options);
        errdefer self.destroy();
        try self.start();
        return self;
    }

    pub fn createStopped(io: std.Io, allocator: std.mem.Allocator, executable_path: []const u8, options: Options) !*ServerProcess {
        var random_bytes: [12]u8 = undefined;
        std.Io.random(io, &random_bytes);
        const suffix = std.fmt.bytesToHex(random_bytes, .lower);
        const data_dir = try std.fmt.allocPrint(allocator, "/tmp/kgcache-integration-{s}", .{suffix});
        var paths_owned_by_self = false;
        errdefer if (!paths_owned_by_self) allocator.free(data_dir);

        const config_path = try std.fmt.allocPrint(allocator, "{s}/kgcache.conf", .{data_dir});
        errdefer if (!paths_owned_by_self) allocator.free(config_path);

        const cwd = std.Io.Dir.cwd();
        try cwd.createDir(io, data_dir, .default_dir);
        var directory_owned = true;
        errdefer if (directory_owned) cwd.deleteTree(io, data_dir) catch {};

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
        self.last_exit_status = null;
        self.ready_bytes_read = 0;

        const port: u16 = if (self.address) |address| address.getPort() else 0;
        const config = try std.fmt.allocPrint(
            self.allocator,
            "bind 127.0.0.1\nport {d}\nreuse-address yes\ncron-interval-ms 20\nsnapshot-path dump.kgc\nappend-dirname aof\nappend-filename appendonly.aof\n{s}",
            .{ port, self.options.extra_config },
        );

        if (self.config) |old| self.allocator.free(old);
        self.config = config;

        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = self.config_path, .data = config });

        var ready_fds: [2]std.posix.fd_t = undefined;
        if (std.c.pipe(&ready_fds) != 0) return error.PipeFailed;
        defer _ = std.c.close(ready_fds[0]);

        var writer_open = true;
        defer if (writer_open) {
            _ = std.c.close(ready_fds[1]);
        };

        var fd_buffer: [16]u8 = undefined;
        const ready_fd_arg = try std.fmt.bufPrint(&fd_buffer, "{d}", .{ready_fds[1]});
        var child = try std.process.spawn(self.io, .{
            .argv = &.{ self.executable_path, "kgcache.conf", "--ready-fd", ready_fd_arg },
            .cwd = .{ .path = self.data_dir },
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
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
    }

    pub fn stop(self: *ServerProcess) !void {
        const pid = self.pid orelse return error.NotRunning;
        std.posix.kill(pid, .TERM) catch |err| switch (err) {
            error.ProcessNotFound => {},
            else => {
                self.failed = true;
                self.forceKill();
                self.joinDrainer();
                self.report("shutdown", err);
                return err;
            },
        };
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
                if (!std.c.W.IFEXITED(code) or std.c.W.EXITSTATUS(code) != 0) {
                    self.failed = true;
                    self.report("shutdown", error.UncleanShutdown);
                    return error.UncleanShutdown;
                }
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
        if (self.pid != null) {
            self.failed = true;
            self.forceKill();
        }
        self.joinDrainer();
        if (self.failed) self.saveFailure();
        std.Io.Dir.cwd().deleteTree(self.io, self.data_dir) catch |err| {
            std.log.err("integration: cannot remove fixture {s}: {s}", .{ self.data_dir, @errorName(err) });
        };
        if (self.config) |config| self.allocator.free(config);
        self.allocator.free(self.config_path);
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
        std.posix.kill(pid, .KILL) catch {};
        var status: c_int = 0;
        while (true) {
            const result = std.c.waitpid(pid, &status, 0);
            if (result == pid) break;
            if (std.posix.errno(result) != .INTR) {
                std.debug.panic("integration: waitpid failed while reaping child {d}", .{pid});
            }
        }
        self.pid = null;
    }

    fn joinDrainer(self: *ServerProcess) void {
        if (self.drainer) |thread| {
            thread.join();
            self.drainer = null;
        }
    }

    fn report(self: *ServerProcess, phase: []const u8, err: anyerror) void {
        if (!self.options.report_failures) return;
        std.log.err("integration: {s} failed: {s}; stdout: {s}; stderr: {s}", .{
            phase, @errorName(err), self.stdout.bytes(), self.stderr.bytes(),
        });
    }

    fn saveFailure(self: *ServerProcess) void {
        const parent = self.options.artifact_dir orelse return;
        const name = std.fs.path.basename(self.data_dir);
        const path = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ parent, name }) catch |err| {
            std.log.err("integration: cannot name failure artifact: {s}", .{@errorName(err)});
            return;
        };
        defer self.allocator.free(path);
        const cwd = std.Io.Dir.cwd();
        cwd.createDirPath(self.io, path) catch |err| {
            std.log.err("integration: cannot create artifact directory: {s}", .{@errorName(err)});
            return;
        };
        const dir = cwd.openDir(self.io, path, .{}) catch |err| {
            std.log.err("integration: cannot open artifact directory: {s}", .{@errorName(err)});
            return;
        };
        defer dir.close(self.io);
        const config = self.config orelse "";
        dir.writeFile(self.io, .{ .sub_path = "kgcache.conf", .data = config[0..@min(config.len, log_limit)] }) catch |err| {
            std.log.err("integration: cannot save config artifact: {s}", .{@errorName(err)});
            return;
        };
        dir.writeFile(self.io, .{ .sub_path = "stdout.log", .data = self.stdout.bytes() }) catch |err| {
            std.log.err("integration: cannot save stdout artifact: {s}", .{@errorName(err)});
            return;
        };
        dir.writeFile(self.io, .{ .sub_path = "stderr.log", .data = self.stderr.bytes() }) catch |err| {
            std.log.err("integration: cannot save stderr artifact: {s}", .{@errorName(err)});
            return;
        };
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
