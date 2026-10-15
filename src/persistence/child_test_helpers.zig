const std = @import("std");
const logging = @import("../logger.zig");
const PersistenceState = @import("../persistence_state.zig");
const object = @import("../object.zig");
const time = @import("../time.zig");

pub const ChildLogger = struct {
    pub const Mode = enum { guard, locked };

    mode: Mode,
    parent_pid: std.posix.pid_t,
    mutex: std.atomic.Mutex = .unlocked,
    held: std.Io.Event = .unset,
    release: std.Io.Event = .unset,
    recorder: logging.TestLogger = .init(),

    pub fn hold(self: *ChildLogger) void {
        self.lock();
        defer self.mutex.unlock();
        self.held.set(std.testing.io);
        self.release.waitUncancelable(std.testing.io);
    }

    pub fn logger(self: *ChildLogger) logging.Logger {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: logging.Logger.VTable = .{ .log = log, .err = err };

    fn enter(self: *ChildLogger) void {
        // Check before entering a lock or recorder in the guard regression.
        if (self.mode == .guard and std.c.getpid() != self.parent_pid) std.c._exit(97);
        self.lock();
    }

    fn log(ptr: *anyopaque, level: logging.Logger.Level, message: []const u8) void {
        const self: *ChildLogger = @ptrCast(@alignCast(ptr));
        self.enter();
        defer self.mutex.unlock();
        self.recorder.logger().log(level, message);
    }

    fn err(ptr: *anyopaque, message: []const u8, source: anyerror, trace: logging.Logger.ErrorTrace) void {
        const self: *ChildLogger = @ptrCast(@alignCast(ptr));
        self.enter();
        defer self.mutex.unlock();
        self.recorder.logger().err(message, source, trace);
    }

    fn lock(self: *ChildLogger) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }
};

pub fn failVisit(_: *anyopaque, _: *anyopaque, _: *const fn (*anyopaque, []const u8, object.Object, ?time.UnixMs) anyerror!void) anyerror!void {
    return error.TestChildWork;
}

pub const Operation = enum { kgc, aof };

pub fn cleanUpChild(state: *PersistenceState, operation: Operation) void {
    const pid = switch (operation) {
        .kgc => if (state._in_flight_kgc_save) |save| save.pid else return,
        .aof => if (state._in_flight_aof_rewrite) |rewrite| rewrite.pid else return,
    };
    PersistenceState.terminateAndReapChild(pid);
}

pub fn expectFailedChild(state: *PersistenceState, operation: Operation) !void {
    const io = std.testing.io;
    const deadline = std.Io.Clock.awake.now(io).toMilliseconds() + 5_000;
    while (true) {
        var tx = state.beginUncancelable();
        const result = switch (operation) {
            .kgc => blk: {
                const result = state.reapKgc(time.nowMs(io));
                break :blk .{ result.status, result.report_error };
            },
            .aof => blk: {
                const result = state.reapAof();
                break :blk .{ result.status, result.report_error };
            },
        };
        tx.end();
        if (result[0] != .running) {
            try std.testing.expectEqual(PersistenceState.ReapResult.failed, result[0]);
            // Only an ordinary exit 1 decodes to failed without a report error.
            try std.testing.expectEqual(@as(?anyerror, null), result[1]);
            return;
        }
        if (std.Io.Clock.awake.now(io).toMilliseconds() >= deadline) return error.ChildExitTimedOut;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}
