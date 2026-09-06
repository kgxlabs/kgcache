const std = @import("std");

const Lock = @This();

pub const Error = error{
    TxCancelled,
};

_io: std.Io,
_mutex: std.Io.Mutex = .init,

pub fn init(io: std.Io) Lock {
    return .{ ._io = io };
}

pub fn begin(self: *Lock) std.Io.Cancelable!Tx {
    try self._mutex.lock(self._io);
    return Tx{
        ._io = self._io,
        ._owner = self,
    };
}

pub fn beginUncancelable(self: *Lock) Tx {
    self._mutex.lockUncancelable(self._io);
    return .{
        ._io = self._io,
        ._owner = self,
    };
}

pub fn tryBegin(self: *Lock) ?Tx {
    const success = self._mutex.tryLock();
    if (!success) return null;

    return Tx{
        ._io = self._io,
        ._owner = self,
    };
}

pub const Tx = struct {
    _io: std.Io,
    _owner: *Lock,
    _active: bool = false,

    pub fn end(self: *Tx) void {
        std.debug.assert(self._active);
        self._active = false;
        self._owner._mutex.unlock(self._io);
    }
};
