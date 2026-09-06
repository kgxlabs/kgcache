const std = @import("std");
const testing = std.testing;

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
        ._owner = self,
    };
}

pub fn beginUncancelable(self: *Lock) Tx {
    self._mutex.lockUncancelable(self._io);
    return .{
        ._owner = self,
    };
}

pub fn tryBegin(self: *Lock) ?Tx {
    const success = self._mutex.tryLock();
    if (!success) return null;

    return Tx{
        ._owner = self,
    };
}

pub const Tx = struct {
    _owner: *Lock,

    pub fn end(self: *Tx) void {
        self._owner._mutex.unlock(self._owner._io);
    }
};

test "begin and end allow another session" {
    var lock = Lock.init(testing.io);
    var first = try lock.begin();
    first.end();

    var second = try lock.begin();
    second.end();
}

test "tryBegin reports an active session as busy" {
    var lock = Lock.init(testing.io);
    var first = try lock.begin();
    try testing.expect(lock.tryBegin() == null);
    first.end();

    var second = lock.tryBegin() orelse return error.ExpectedLockSession;
    second.end();
}

test "beginUncancelable returns a usable session" {
    var lock = Lock.init(testing.io);
    var first = lock.beginUncancelable();
    first.end();

    var second = try lock.begin();
    second.end();
}
