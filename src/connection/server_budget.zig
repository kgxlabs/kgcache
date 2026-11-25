const std = @import("std");
const Lock = @import("../lock.zig");

const ServerBudget = @This();

pub const Limits = struct {
    max_connections: usize,
    max_buffer_bytes: usize,

    pub fn validate(self: Limits) error{InvalidServerBudgetLimits}!void {
        _ = self;
        @panic("ServerBudget.Limits.validate is not implemented");
    }
};

_lock: Lock,
_limits: Limits,
_connections_used: usize = 0,
_buffer_bytes_used: usize = 0,

pub fn init(io: std.Io, limits: Limits) ServerBudget {
    return .{ ._lock = Lock.init(io), ._limits = limits };
}

// Null means a normal resource refusal. A reservation performs no allocation.
pub fn reserveNewSession(self: *ServerBudget, initial_buffer_bytes: usize) ?Reservation {
    _ = .{ self, initial_buffer_bytes };
    @panic("ServerBudget.reserveNewSession is not implemented");
}

// Move with the connection. The budget must outlive every outstanding token.
pub const Reservation = struct {
    budget: *ServerBudget,
    buffer_bytes: usize,

    pub fn tryReserveBuffer(self: *Reservation, bytes: usize) bool {
        _ = .{ self, bytes };
        @panic("ServerBudget.Reservation.tryReserveBuffer is not implemented");
    }

    pub fn releaseBuffer(self: *Reservation, bytes: usize) void {
        _ = .{ self, bytes };
        @panic("ServerBudget.Reservation.releaseBuffer is not implemented");
    }

    // Return the connection slot and remaining allowance exactly once.
    pub fn release(self: *Reservation) void {
        _ = self;
        @panic("ServerBudget.Reservation.release is not implemented");
    }
};
