const std = @import("std");

const PersistenceState = @This();

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

pub fn reapKgc(self: *PersistenceState) void {
    self.reapPid("kgc", &self._kgc_pid, &self._kgc_in_progress);
}

pub fn reapAof(self: *PersistenceState) void {
    self.reapPid("aof", &self._aof_pid, &self._aof_in_progress);
}

fn reapPid(self: *PersistenceState, name: []const u8, maybe_pid: *?std.posix.pid_t, in_progress: *bool) void {
    self._mutex.lockUncancelable(self._io);
    defer self._mutex.unlock(self._io);
    const pid = maybe_pid.* orelse return;
    var status: c_int = undefined;
    const r = std.posix.system.waitpid(pid, &status, std.c.W.NOHANG);
    // Child porcess is still running
    if (r == 0) return;
    maybe_pid.* = null;
    in_progress.* = false;

    const status_bits: u32 = @bitCast(status);
    // If child process exited normally with non-zero exit code, std err
    if (std.c.W.IFEXITED(status_bits) and std.c.W.EXITSTATUS(status_bits) != 0) {
        var buf: [128]u8 = undefined;
        const message = std.fmt.bufPrint(
            &buf,
            "kgcache: {s} background save child exited with status {d}\n",
            .{ name, std.c.W.EXITSTATUS(status_bits) },
        ) catch "kgcache: background save child exited with a failure status\n";
        std.Io.File.writeStreamingAll(std.Io.File.stderr(), self._io, message) catch {};
    }
}
