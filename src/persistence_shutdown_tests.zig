const std = @import("std");
const Server = @import("server.zig");
const Config = @import("config.zig");
const PersistenceState = @import("persistence_state.zig");
const Manifest = @import("persistence/manifest.zig");
const logging = @import("logger.zig");

const testing = std.testing;

const Scratch = struct {
    tmp: testing.TmpDir,
    snapshot_path: []u8,
    aof_dir: []u8,

    fn init() !Scratch {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const snapshot_path = try std.fmt.allocPrint(
            testing.allocator,
            ".zig-cache/tmp/{s}/dump.kgc",
            .{tmp.sub_path},
        );
        errdefer testing.allocator.free(snapshot_path);
        const aof_dir = try std.fmt.allocPrint(
            testing.allocator,
            ".zig-cache/tmp/{s}/appendonlydir",
            .{tmp.sub_path},
        );
        return .{ .tmp = tmp, .snapshot_path = snapshot_path, .aof_dir = aof_dir };
    }

    fn config(self: *const Scratch, append_only: bool) Config {
        var result = Config.default();
        result.snapshot_path = self.snapshot_path;
        result.append_dirname = self.aof_dir;
        result.append_only = append_only;
        result.append_fsync = .always;
        result.exclusive_bg_persistence = false;
        result.num_databases = 1;
        return result;
    }

    fn deinit(self: *Scratch) void {
        testing.allocator.free(self.aof_dir);
        testing.allocator.free(self.snapshot_path);
        self.tmp.cleanup();
    }
};

// Fork hooks only hold real children at a pipe barrier. The assertions below
// check shutdown, waitpid, and persisted data.
const ChildGate = struct {
    ready: [2]std.posix.fd_t,
    release_pipe: [2]std.posix.fd_t,
    pid: std.atomic.Value(std.posix.pid_t) = .init(0),
    forked: std.Io.Event = .unset,
    fail_child: bool,
    released: bool = false,

    fn init(fail_child: bool) !ChildGate {
        var ready: [2]std.posix.fd_t = undefined;
        if (std.c.pipe(&ready) != 0) return error.PipeFailed;
        errdefer {
            _ = std.c.close(ready[0]);
            _ = std.c.close(ready[1]);
        }
        var release_pipe: [2]std.posix.fd_t = undefined;
        if (std.c.pipe(&release_pipe) != 0) return error.PipeFailed;
        return .{ .ready = ready, .release_pipe = release_pipe, .fail_child = fail_child };
    }

    fn fork(self: *ChildGate) anyerror!std.posix.pid_t {
        const rc = std.posix.system.fork();
        if (rc < 0) {
            self.forked.set(testing.io);
            return error.ChildForkFailed;
        }
        if (rc == 0) {
            _ = std.c.close(self.ready[0]);
            _ = std.c.close(self.release_pipe[1]);
            var token = [_]u8{1};
            if (std.c.write(self.ready[1], &token, 1) != 1) std.c._exit(2);
            while (true) {
                const count = std.c.read(self.release_pipe[0], &token, 1);
                if (count == 1) break;
                if (count < 0 and std.posix.errno(count) == .INTR) continue;
                std.c._exit(2);
            }
            if (self.fail_child) std.c._exit(1);
            return 0;
        }
        self.pid.store(@intCast(rc), .release);
        self.forked.set(testing.io);
        return @intCast(rc);
    }

    fn awaitReady(self: *ChildGate) !std.posix.pid_t {
        self.forked.waitUncancelable(testing.io);
        const child_pid = self.pid.load(.acquire);
        if (child_pid <= 0) return error.ChildForkFailed;
        var token: [1]u8 = undefined;
        while (true) {
            const count = std.c.read(self.ready[0], &token, 1);
            if (count == 1) return child_pid;
            if (count < 0 and std.posix.errno(count) == .INTR) continue;
            return error.ChildBarrierFailed;
        }
    }

    fn release(self: *ChildGate) void {
        if (self.released) return;
        self.released = true;
        var token = [_]u8{1};
        _ = std.c.write(self.release_pipe[1], &token, 1);
    }

    fn deinit(self: *ChildGate) void {
        self.release();
        const child_pid = self.pid.load(.acquire);
        if (child_pid > 0) {
            var status: c_int = undefined;
            const result = std.posix.system.waitpid(child_pid, &status, std.c.W.NOHANG);
            if (result == 0) {
                std.posix.kill(child_pid, .KILL) catch {};
                while (true) {
                    const waited = std.posix.system.waitpid(child_pid, &status, 0);
                    if (waited >= 0 or std.posix.errno(waited) != .INTR) break;
                }
            }
        }
        _ = std.c.close(self.ready[0]);
        _ = std.c.close(self.ready[1]);
        _ = std.c.close(self.release_pipe[0]);
        _ = std.c.close(self.release_pipe[1]);
    }
};

var gate_mutex: std.atomic.Mutex = .unlocked;
var kgc_gate: ?*ChildGate = null;
var aof_gate: ?*ChildGate = null;

fn lockGates() void {
    while (!gate_mutex.tryLock()) std.atomic.spinLoopHint();
}

fn forkKgc() anyerror!std.posix.pid_t {
    return kgc_gate.?.fork();
}

fn forkAof() anyerror!std.posix.pid_t {
    return aof_gate.?.fork();
}

const WaitObserver = struct {
    io: std.Io,
    first_wait: std.Io.Event = .unset,
    second_wait: std.Io.Event = .unset,
    info_count: std.atomic.Value(usize) = .init(0),

    fn logger(self: *WaitObserver) logging.Logger {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: logging.Logger.VTable = .{ .log = log, .err = err };

    fn log(ptr: *anyopaque, _: logging.Logger.Level, _: []const u8) void {
        const self: *WaitObserver = @ptrCast(@alignCast(ptr));
        const index = self.info_count.fetchAdd(1, .acq_rel);
        if (index == 0) self.first_wait.set(self.io);
        if (index == 1) self.second_wait.set(self.io);
    }

    fn err(_: *anyopaque, _: []const u8, _: anyerror, _: logging.Logger.ErrorTrace) void {}
};

const DestroyTask = struct {
    server: *Server,
    io: std.Io,
    done: std.Io.Event = .unset,
    finished: std.atomic.Value(bool) = .init(false),
    err: ?anyerror = null,

    fn run(self: *DestroyTask) void {
        self.server.destroy() catch |err| {
            self.err = err;
        };
        self.finished.store(true, .release);
        self.done.set(self.io);
    }
};

const WaitRace = union(enum) {
    waiting: std.Io.Cancelable!void,
    finished: std.Io.Cancelable!void,
};

fn waitEvent(io: std.Io, event: *std.Io.Event) std.Io.Cancelable!void {
    try event.wait(io);
}

fn expectShutdownWaiting(wait_event: *std.Io.Event, task: *DestroyTask) !void {
    var results: [2]WaitRace = undefined;
    var select = std.Io.Select(WaitRace).init(testing.io, &results);
    defer select.cancelDiscard();
    try select.concurrent(.waiting, waitEvent, .{ testing.io, wait_event });
    try select.concurrent(.finished, waitEvent, .{ testing.io, &task.done });
    switch (try select.await()) {
        .waiting => |result| try result,
        .finished => |result| {
            try result;
            return error.ShutdownReturnedBeforeChildRelease;
        },
    }
    try testing.expect(!task.finished.load(.acquire));
}

fn destroyAfterWait(server: *Server, wait_event: *std.Io.Event, gate: *ChildGate, server_destroyed: *bool) !?anyerror {
    var task: DestroyTask = .{ .server = server, .io = testing.io };
    const thread = try std.Thread.spawn(.{}, DestroyTask.run, .{&task});
    var joined = false;
    defer if (!joined) {
        gate.release();
        thread.join();
        server_destroyed.* = true;
    };

    try expectShutdownWaiting(wait_event, &task);
    gate.release();
    thread.join();
    joined = true;
    server_destroyed.* = true;
    return task.err;
}

fn expectReaped(pid: std.posix.pid_t) !void {
    var status: c_int = undefined;
    const result = std.posix.system.waitpid(pid, &status, std.c.W.NOHANG);
    try testing.expectEqual(@as(std.posix.pid_t, -1), result);
    try testing.expectEqual(std.posix.E.CHILD, std.posix.errno(result));
}

fn setValue(server: *Server, key: []const u8, value: []const u8) !void {
    _ = try server._store.set(.{
        .key = key,
        .value = value,
        .condition = null,
        .expires_at = null,
        .keepttl = false,
        .response = null,
    }, 0);
}

fn expectValue(server: *Server, key: []const u8, expected: []const u8) !void {
    var loaded = try server._store.get(key, 0) orelse return error.MissingPersistedValue;
    defer loaded.deinit();
    try testing.expectEqualStrings(expected, loaded.value.string);
}

const BgsaveClientIo = struct {
    base_io: std.Io,
    request_sent: std.atomic.Value(bool) = .init(false),
    read_entered: std.Io.Event = .unset,
    release_read: std.Io.Event = .unset,
    shutdown_called: std.Io.Event = .unset,
    fail_shutdown: bool,
    vtable: std.Io.VTable = undefined,

    const request = "*1\r\n$6\r\nBGSAVE\r\n";

    fn io(self: *BgsaveClientIo) std.Io {
        self.vtable = self.base_io.vtable.*;
        self.vtable.netRead = netRead;
        self.vtable.netWrite = netWrite;
        self.vtable.netClose = netClose;
        self.vtable.netShutdown = netShutdown;
        return .{ .userdata = self, .vtable = &self.vtable };
    }

    fn stream() std.Io.net.Stream {
        return .{ .socket = .{ .handle = 1, .address = undefined } };
    }

    fn netRead(
        userdata: ?*anyopaque,
        _: std.Io.net.Socket.Handle,
        data: [][]u8,
    ) std.Io.net.Stream.Reader.Error!usize {
        const self: *BgsaveClientIo = @ptrCast(@alignCast(userdata));
        if (self.request_sent.swap(true, .acq_rel)) return 0;
        self.read_entered.set(self.base_io);
        self.release_read.waitUncancelable(self.base_io);
        @memcpy(data[0][0..request.len], request);
        return request.len;
    }

    fn netWrite(
        _: ?*anyopaque,
        _: std.Io.net.Socket.Handle,
        header: []const u8,
        data: []const []const u8,
        splat: usize,
    ) std.Io.net.Stream.Writer.Error!usize {
        var bytes_written = header.len;
        for (data[0 .. data.len - 1]) |part| bytes_written += part.len;
        if (splat > 0) bytes_written += data[data.len - 1].len * splat;
        return bytes_written;
    }

    fn netShutdown(
        userdata: ?*anyopaque,
        _: std.Io.net.Socket.Handle,
        _: std.Io.net.ShutdownHow,
    ) std.Io.net.ShutdownError!void {
        const self: *BgsaveClientIo = @ptrCast(@alignCast(userdata));
        self.shutdown_called.set(self.base_io);
        self.release_read.set(self.base_io);
        if (self.fail_shutdown) return error.ConnectionAborted;
    }

    fn netClose(_: ?*anyopaque, _: []const std.Io.net.Socket.Handle) void {}
};

test "shutdown waits for active BGSAVE and restart loads its snapshot" {
    lockGates();
    defer gate_mutex.unlock();

    var scratch = try Scratch.init();
    defer scratch.deinit();
    var gate = try ChildGate.init(false);
    defer gate.deinit();
    kgc_gate = &gate;
    defer kgc_gate = null;

    const config = scratch.config(false);
    var observer: WaitObserver = .{ .io = testing.io };
    const server = try Server.create(testing.io, testing.allocator, config, observer.logger());
    var server_destroyed = false;
    defer if (!server_destroyed) {
        gate.release();
        server.destroy() catch {};
    };
    server._kgc._fork = forkKgc;
    try setValue(server, "snapshot-key", "saved");
    try testing.expectEqual(PersistenceState.BackgroundStartOutcome.started, try server._store.bgsave(.manual));
    const pid = try gate.awaitReady();

    const result = try destroyAfterWait(server, &observer.first_wait, &gate, &server_destroyed);
    try testing.expectEqual(null, result);
    try expectReaped(pid);

    const restarted = try Server.create(testing.io, testing.allocator, config, logging.NoopLogger.logger());
    defer restarted.destroy() catch unreachable;
    try expectValue(restarted, "snapshot-key", "saved");
}

test "shutdown waits for active BGREWRITEAOF and restart replays later writes" {
    lockGates();
    defer gate_mutex.unlock();

    var scratch = try Scratch.init();
    defer scratch.deinit();
    var gate = try ChildGate.init(false);
    defer gate.deinit();
    aof_gate = &gate;
    defer aof_gate = null;

    const config = scratch.config(true);
    var observer: WaitObserver = .{ .io = testing.io };
    const server = try Server.create(testing.io, testing.allocator, config, observer.logger());
    var server_destroyed = false;
    defer if (!server_destroyed) {
        gate.release();
        server.destroy() catch {};
    };
    server._aof.?._fork = forkAof;
    try setValue(server, "base-key", "base-value");
    try testing.expectEqual(PersistenceState.BackgroundStartOutcome.started, try server._store.bgrewriteaof(.manual));
    const pid = try gate.awaitReady();
    try setValue(server, "later-key", "later-value");

    const result = try destroyAfterWait(server, &observer.first_wait, &gate, &server_destroyed);
    try testing.expectEqual(null, result);
    try expectReaped(pid);

    const restarted = try Server.create(testing.io, testing.allocator, config, logging.NoopLogger.logger());
    defer restarted.destroy() catch unreachable;
    try expectValue(restarted, "base-key", "base-value");
    try expectValue(restarted, "later-key", "later-value");

    var dir = try std.Io.Dir.cwd().openDir(testing.io, scratch.aof_dir, .{});
    defer dir.close(testing.io);
    const manifest = try Manifest.read(testing.io, testing.allocator, dir, "appendonly.aof.manifest") orelse return error.MissingAofManifest;
    defer manifest.deinit(testing.allocator);
    try testing.expect(manifest.base != null);
}

test "failed BGSAVE during shutdown keeps the previous snapshot" {
    lockGates();
    defer gate_mutex.unlock();

    var scratch = try Scratch.init();
    defer scratch.deinit();
    var gate = try ChildGate.init(true);
    defer gate.deinit();
    kgc_gate = &gate;
    defer kgc_gate = null;

    const config = scratch.config(false);
    var observer: WaitObserver = .{ .io = testing.io };
    const server = try Server.create(testing.io, testing.allocator, config, observer.logger());
    var server_destroyed = false;
    defer if (!server_destroyed) {
        gate.release();
        server.destroy() catch {};
    };
    try setValue(server, "snapshot-key", "previous");
    try server._store.save();
    server._kgc._fork = forkKgc;
    try setValue(server, "snapshot-key", "unsaved");
    try testing.expectEqual(PersistenceState.BackgroundStartOutcome.started, try server._store.bgsave(.manual));
    const pid = try gate.awaitReady();

    const result = try destroyAfterWait(server, &observer.first_wait, &gate, &server_destroyed);
    try testing.expectEqual(error.BackgroundSaveFailed, result.?);
    try expectReaped(pid);

    const restarted = try Server.create(testing.io, testing.allocator, config, logging.NoopLogger.logger());
    defer restarted.destroy() catch unreachable;
    try expectValue(restarted, "snapshot-key", "previous");
}

test "failed BGREWRITEAOF during shutdown keeps acknowledged writes" {
    lockGates();
    defer gate_mutex.unlock();

    var scratch = try Scratch.init();
    defer scratch.deinit();
    var gate = try ChildGate.init(true);
    defer gate.deinit();
    aof_gate = &gate;
    defer aof_gate = null;

    const config = scratch.config(true);
    var observer: WaitObserver = .{ .io = testing.io };
    const server = try Server.create(testing.io, testing.allocator, config, observer.logger());
    var server_destroyed = false;
    defer if (!server_destroyed) {
        gate.release();
        server.destroy() catch {};
    };
    server._aof.?._fork = forkAof;
    try setValue(server, "before-key", "before-value");
    try testing.expectEqual(PersistenceState.BackgroundStartOutcome.started, try server._store.bgrewriteaof(.manual));
    const pid = try gate.awaitReady();
    try setValue(server, "after-key", "after-value");

    const result = try destroyAfterWait(server, &observer.first_wait, &gate, &server_destroyed);
    try testing.expectEqual(error.AofRewriteFailed, result.?);
    try expectReaped(pid);

    const restarted = try Server.create(testing.io, testing.allocator, config, logging.NoopLogger.logger());
    defer restarted.destroy() catch unreachable;
    try expectValue(restarted, "before-key", "before-value");
    try expectValue(restarted, "after-key", "after-value");

    var dir = try std.Io.Dir.cwd().openDir(testing.io, scratch.aof_dir, .{});
    defer dir.close(testing.io);
    const manifest = try Manifest.read(testing.io, testing.allocator, dir, "appendonly.aof.manifest") orelse return error.MissingAofManifest;
    defer manifest.deinit(testing.allocator);
    try testing.expect(manifest.base == null);
}

test "shutdown waits for both BGSAVE and BGREWRITEAOF children" {
    lockGates();
    defer gate_mutex.unlock();

    var scratch = try Scratch.init();
    defer scratch.deinit();
    var save_gate = try ChildGate.init(false);
    defer save_gate.deinit();
    var rewrite_gate = try ChildGate.init(false);
    defer rewrite_gate.deinit();
    kgc_gate = &save_gate;
    defer kgc_gate = null;
    aof_gate = &rewrite_gate;
    defer aof_gate = null;

    const config = scratch.config(true);
    var observer: WaitObserver = .{ .io = testing.io };
    const server = try Server.create(testing.io, testing.allocator, config, observer.logger());
    var server_destroyed = false;
    defer if (!server_destroyed) {
        save_gate.release();
        rewrite_gate.release();
        server.destroy() catch {};
    };
    server._kgc._fork = forkKgc;
    server._aof.?._fork = forkAof;
    try setValue(server, "both-key", "both-value");
    try testing.expectEqual(PersistenceState.BackgroundStartOutcome.started, try server._store.bgsave(.manual));
    const save_pid = try save_gate.awaitReady();
    try testing.expectEqual(PersistenceState.BackgroundStartOutcome.started, try server._store.bgrewriteaof(.manual));
    const rewrite_pid = try rewrite_gate.awaitReady();

    var task: DestroyTask = .{ .server = server, .io = testing.io };
    const thread = try std.Thread.spawn(.{}, DestroyTask.run, .{&task});
    var joined = false;
    defer if (!joined) {
        save_gate.release();
        rewrite_gate.release();
        thread.join();
        server_destroyed = true;
    };
    try expectShutdownWaiting(&observer.first_wait, &task);
    save_gate.release();
    try expectShutdownWaiting(&observer.second_wait, &task);
    rewrite_gate.release();
    thread.join();
    joined = true;
    server_destroyed = true;

    try testing.expectEqual(null, task.err);
    try expectReaped(save_pid);
    try expectReaped(rewrite_pid);

    const restarted = try Server.create(testing.io, testing.allocator, config, logging.NoopLogger.logger());
    defer restarted.destroy() catch unreachable;
    try expectValue(restarted, "both-key", "both-value");
}

fn runWorkerBgsaveShutdown(fail_shutdown: bool, fail_child: bool) !void {
    lockGates();
    defer gate_mutex.unlock();

    var scratch = try Scratch.init();
    defer scratch.deinit();
    var gate = try ChildGate.init(fail_child);
    defer gate.deinit();
    kgc_gate = &gate;
    defer kgc_gate = null;

    const config = scratch.config(false);
    var observer: WaitObserver = .{ .io = testing.io };
    const server = try Server.create(testing.io, testing.allocator, config, observer.logger());
    var server_destroyed = false;
    defer if (!server_destroyed) {
        gate.release();
        server.destroy() catch {};
    };

    try setValue(server, "worker-key", "previous");
    try server._store.save();
    try setValue(server, "worker-key", "from-worker");
    server._kgc._fork = forkKgc;

    var client: BgsaveClientIo = .{ .base_io = testing.io, .fail_shutdown = fail_shutdown };
    defer client.release_read.set(testing.io);
    server._connection_manager._io = client.io();
    try server._connection_manager.start(BgsaveClientIo.stream());
    client.read_entered.waitUncancelable(testing.io);

    var task: DestroyTask = .{ .server = server, .io = testing.io };
    const thread = try std.Thread.spawn(.{}, DestroyTask.run, .{&task});
    var joined = false;
    defer if (!joined) {
        client.release_read.set(testing.io);
        gate.release();
        thread.join();
        server_destroyed = true;
    };

    client.shutdown_called.waitUncancelable(testing.io);
    try testing.expect(!task.finished.load(.acquire));
    const pid = try gate.awaitReady();
    try expectShutdownWaiting(&observer.first_wait, &task);
    gate.release();
    thread.join();
    joined = true;
    server_destroyed = true;

    if (fail_shutdown) {
        try testing.expectEqual(error.ConnectionAborted, task.err.?);
    } else {
        try testing.expectEqual(null, task.err);
    }
    try expectReaped(pid);

    const restarted = try Server.create(testing.io, testing.allocator, config, logging.NoopLogger.logger());
    defer restarted.destroy() catch unreachable;
    try expectValue(restarted, "worker-key", if (fail_child) "previous" else "from-worker");
}

test "shutdown drains a BGSAVE started by a client worker while workers join" {
    try runWorkerBgsaveShutdown(false, false);
}

test "shutdown preserves worker cleanup error after failed BGSAVE" {
    try runWorkerBgsaveShutdown(true, true);
}
