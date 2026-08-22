const std = @import("std");

const PersistanceState = @This();

_io: std.Io,
_mutex: std.Io.Mutex = .init,
_kgc_in_progress: bool = false,
_aof_in_progress: bool = false,
_mutual_exclusive: bool = false,
_kgc_pid: ?std.posix.pid_t = null,
_aof_pid: ?std.posix.pid_t = null,

pub fn init(io: std.Io, mutual_exclusive: bool) PersistanceState {
    return .{
        ._io = io,
        ._mutual_exclusive = mutual_exclusive,
    };
}

pub fn tryStartKgc(self: *PersistanceState) bool {
    self._mutex.lock(self._io);
    defer self._mutex.unlock(self._io);

    if (self._kgc_in_progress) return false;
    if (self._mutual_exclusive and self._aof_in_progress) return false;
    self._kgc_in_progress = true;
    return true;
}

pub fn finishKgc(self: *PersistanceState) void {
    self._mutex.lock(self._io);
    defer self._mutex.unlock(self._io);

    self._kgc_in_progress = null;
}

pub fn tryStartAof(self: *PersistanceState) bool {
    self._mutex.lock(self._io);
    defer self._mutex.unlock(self._io);

    if (self._aof_in_progress) return false;
    if (self._mutual_exclusive and self._kgc_in_progress) return false;
    self._aof_in_progress = true;
    return true;
}

pub fn finishAof(self: *PersistanceState) void {
    self._mutex.lock(self._io);
    defer self._mutex.unlock(self._io);

    self._aof_in_progress = null;
}
