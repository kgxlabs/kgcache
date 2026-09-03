const std = @import("std");

const PersistenceState = @This();

pub const ReapResult = enum {
    running,
    succeeded,
    failed,
};

_io: std.Io,
_mutex: std.Io.Mutex = .init,
_kgc_in_progress: bool = false,
_aof_in_progress: bool = false,
_mutual_exclusive: bool = false,
_kgc_pid: ?std.posix.pid_t = null,
_aof_pid: ?std.posix.pid_t = null,

pub fn init(io: std.Io, mutual_exclusive: bool) PersistenceState {
    return .{
        ._io = io,
        ._mutual_exclusive = mutual_exclusive,
    };
}

pub fn tryStartKgc(self: *PersistenceState) bool {
    self._mutex.lockUncancelable(self._io);
    defer self._mutex.unlock(self._io);

    if (self._kgc_in_progress) return false;
    if (self._mutual_exclusive and self._aof_in_progress) return false;
    self._kgc_in_progress = true;
    return true;
}

pub fn setKgcPid(self: *PersistenceState, pid: std.posix.pid_t) void {
    self._mutex.lockUncancelable(self._io);
    defer self._mutex.unlock(self._io);
    self._kgc_pid = pid;
}

pub fn finishKgc(self: *PersistenceState) void {
    self._mutex.lockUncancelable(self._io);
    defer self._mutex.unlock(self._io);

    self._kgc_in_progress = false;
}

pub fn tryStartAof(self: *PersistenceState) bool {
    self._mutex.lockUncancelable(self._io);
    defer self._mutex.unlock(self._io);

    if (self._aof_in_progress) return false;
    if (self._mutual_exclusive and self._kgc_in_progress) return false;
    self._aof_in_progress = true;
    return true;
}

pub fn setAofPid(self: *PersistenceState, pid: std.posix.pid_t) void {
    self._mutex.lockUncancelable(self._io);
    defer self._mutex.unlock(self._io);

    self._aof_pid = pid;
}

pub fn finishAof(self: *PersistenceState) void {
    self._mutex.lockUncancelable(self._io);
    defer self._mutex.unlock(self._io);

    self._aof_in_progress = false;
}

pub fn aofInProgress(self: *PersistenceState) bool {
    self._mutex.lockUncancelable(self._io);
    defer self._mutex.unlock(self._io);

    return self._aof_in_progress;
}

pub fn reapKgc(self: *PersistenceState) ReapResult {
    return self.reapPid("kgc", &self._kgc_pid, &self._kgc_in_progress);
}

pub fn reapAof(self: *PersistenceState) ReapResult {
    return self.reapPid("aof", &self._aof_pid, &self._aof_in_progress);
}

// A completed child is reported exactly once. With no pid there is no
// completion event, so callers receive .running and do no follow-up work.
fn reapPid(self: *PersistenceState, name: []const u8, maybe_pid: *?std.posix.pid_t, in_progress: *bool) ReapResult {
    self._mutex.lockUncancelable(self._io);
    defer self._mutex.unlock(self._io);

    // No pid means there is no completion event for the caller to handle.
    const pid = maybe_pid.* orelse return .running;

    var status: c_int = undefined;
    const r = std.posix.system.waitpid(pid, &status, std.c.W.NOHANG);
    // Child porcess is still running
    if (r == 0) return .running;
    maybe_pid.* = null;
    in_progress.* = false;

    const status_bits: u32 = @bitCast(status);
    // Only a normal zero exit proves the child completed its persistence
    // work. A non-zero exit or signal termination must never publish output.
    if (!std.c.W.IFEXITED(status_bits) or std.c.W.EXITSTATUS(status_bits) != 0) {
        var buf: [128]u8 = undefined;
        const message = if (std.c.W.IFEXITED(status_bits))
            std.fmt.bufPrint(
                &buf,
                "kgcache: {s} background save child exited with status {d}\n",
                .{ name, std.c.W.EXITSTATUS(status_bits) },
            ) catch "kgcache: background save child exited with a failure status\n"
        else
            std.fmt.bufPrint(
                &buf,
                "kgcache: {s} background save child terminated abnormally\n",
                .{name},
            ) catch "kgcache: background save child terminated abnormally\n";
        std.Io.File.writeStreamingAll(std.Io.File.stderr(), self._io, message) catch {};
        // even though this is triggered but failed scenario, we will reset the tracker
        return .failed;
    }

    return .succeeded;
}

test "tryStartKgc blocks a second start until finishKgc releases it" {
    const testing = std.testing;
    var state = PersistenceState.init(testing.io, false);

    try testing.expect(state.tryStartKgc());
    try testing.expect(!state.tryStartKgc());

    state.finishKgc();

    try testing.expect(state.tryStartKgc());
}

test "tryStartAof blocks a second start until finishAof releases it" {
    const testing = std.testing;
    var state = PersistenceState.init(testing.io, false);

    try testing.expect(state.tryStartAof());
    try testing.expect(!state.tryStartAof());

    state.finishAof();

    try testing.expect(state.tryStartAof());
}

test "mutual exclusion blocks kgc while aof is in progress" {
    const testing = std.testing;
    var state = PersistenceState.init(testing.io, true);

    try testing.expect(state.tryStartAof());
    try testing.expect(!state.tryStartKgc());

    state.finishAof();

    try testing.expect(state.tryStartKgc());
}

test "mutual exclusion blocks aof while kgc is in progress" {
    const testing = std.testing;
    var state = PersistenceState.init(testing.io, true);

    try testing.expect(state.tryStartKgc());
    try testing.expect(!state.tryStartAof());

    state.finishKgc();

    try testing.expect(state.tryStartAof());
}

test "without mutual exclusion kgc and aof can be in progress at the same time" {
    const testing = std.testing;
    var state = PersistenceState.init(testing.io, false);

    try testing.expect(state.tryStartKgc());
    try testing.expect(state.tryStartAof());
}

test "reapKgc leaves state untouched while the child is still running" {
    const testing = std.testing;
    var state = PersistenceState.init(testing.io, false);
    try testing.expect(state.tryStartKgc());

    // A pipe lets the parent control exactly when the forked child exits,
    // instead of racing a real timing window.
    var fds: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.PipeFailed;

    const rc = std.posix.system.fork();
    const pid: std.posix.pid_t = switch (std.posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        else => |err| return std.posix.unexpectedErrno(err),
    };

    if (pid == 0) {
        // Close inherited stdin/stdout so this test child doesn't keep a
        // duplicate of the build system's IPC channel open under `zig build test`.
        _ = std.c.close(std.posix.STDIN_FILENO);
        _ = std.c.close(std.posix.STDOUT_FILENO);

        _ = std.c.close(fds[1]);
        var byte: [1]u8 = undefined;
        _ = std.c.read(fds[0], &byte, 1);
        _ = std.c.close(fds[0]);
        std.c._exit(0);
    }
    _ = std.c.close(fds[0]);
    state.setKgcPid(pid);

    try testing.expect(state.reapKgc() == .running);
    try testing.expect(state._kgc_in_progress);
    try testing.expect(state._kgc_pid != null);

    var byte: [1]u8 = .{1};
    _ = std.c.write(fds[1], &byte, 1);
    _ = std.c.close(fds[1]);

    var tries: usize = 0;
    while (state._kgc_pid != null) {
        _ = state.reapKgc();
        tries += 1;
        if (tries > 100_000) return error.ChildNeverReaped;
    }

    try testing.expect(!state._kgc_in_progress);
}

test "reapKgc clears state after the child exits with a failure status" {
    const testing = std.testing;
    var state = PersistenceState.init(testing.io, false);
    try testing.expect(state.tryStartKgc());

    const rc = std.posix.system.fork();
    const pid: std.posix.pid_t = switch (std.posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        else => |err| return std.posix.unexpectedErrno(err),
    };

    if (pid == 0) {
        _ = std.c.close(std.posix.STDIN_FILENO);
        _ = std.c.close(std.posix.STDOUT_FILENO);
        std.c._exit(7);
    }
    state.setKgcPid(pid);

    // reapKgc logs to the real stderr when it observes a non-zero exit --
    // exactly what this test exercises. Left alone, that write lands in the
    // test binary's own stderr, and `zig build test` flags an otherwise
    // fully-passing run as a "failed command" because of it. Redirect
    // stderr to /dev/null only for the reap loop, then restore it, so the
    // logging code still runs for real without polluting captured output.
    const devnull = std.c.open("/dev/null", .{ .ACCMODE = .WRONLY });
    if (devnull < 0) return error.OpenDevNullFailed;
    defer _ = std.c.close(devnull);

    const saved_stderr = std.c.dup(std.posix.STDERR_FILENO);
    if (saved_stderr < 0) return error.DupFailed;
    defer {
        _ = std.c.dup2(saved_stderr, std.posix.STDERR_FILENO);
        _ = std.c.close(saved_stderr);
    }
    _ = std.c.dup2(devnull, std.posix.STDERR_FILENO);

    var tries: usize = 0;
    while (state._kgc_pid != null) {
        _ = state.reapKgc();
        tries += 1;
        if (tries > 100_000) return error.ChildNeverReaped;
    }

    try testing.expect(!state._kgc_in_progress);
}
