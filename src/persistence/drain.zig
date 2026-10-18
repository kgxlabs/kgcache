const std = @import("std");
const PersistenceState = @import("../persistence_state.zig");
const JournalPersistence = @import("journal_interface.zig");
const logging = @import("../logger.zig");
const time = @import("../time.zig");

pub const Result = struct {
    status: Status,
    err: ?anyerror,
};

pub const Status = enum {
    complete,
    aof_unresolved,
    children_unresolved,
};

const ShutdownState = enum {
    ready,
    child_tracked,
    aof_unresolved,
};

pub const Options = struct {
    // Both children share this graceful-work budget.
    grace_ms: u32 = 10_000,
    // This bounds polling after SIGKILL, not kernel termination latency.
    reap_ms: u32 = 1_000,
};

/// Keep one context for all persistence work in a shutdown.
pub const Context = struct {
    _work_deadline_ms: i64,
    _reap_deadline_ms: ?i64 = null,
    _reap_ms: u32,
    _err: ?anyerror = null,
    _poll_errors: PollErrors = .{},
    _unresolved_reported: bool = false,

    pub fn init(io: std.Io, options: Options) Context {
        return .{
            ._work_deadline_ms = std.Io.Clock.awake.now(io).toMilliseconds() +| options.grace_ms,
            ._reap_ms = options.reap_ms,
        };
    }

    /// Time left for new work. Returns zero once termination starts.
    pub fn remainingMs(self: *const Context, io: std.Io) i64 {
        if (self._reap_deadline_ms != null) return 0;
        return @max(0, self._work_deadline_ms -| std.Io.Clock.awake.now(io).toMilliseconds());
    }

    pub fn workDeadlineMs(self: *const Context) i64 {
        return self._work_deadline_ms;
    }

    /// Call after cron and all client workers have joined.
    pub fn run(
        self: *Context,
        io: std.Io,
        logger: logging.Logger,
        state: *PersistenceState,
        maybe_aof: ?JournalPersistence,
    ) Result {
        // TODO: add child output to shutdown logs (#227).
        logChildren(logger, state);

        while (true) {
            drainOnce(io, logger, state, maybe_aof, &self._err, &self._poll_errors);

            switch (getShutdownState(state, maybe_aof)) {
                .ready => return .{ .status = .complete, .err = self._err },
                .child_tracked => {
                    const now = std.Io.Clock.awake.now(io).toMilliseconds();
                    const deadline = self._reap_deadline_ms orelse self._work_deadline_ms;

                    if (now >= deadline) {
                        if (self._reap_deadline_ms != null) {
                            if (!self._unresolved_reported) {
                                recordError(
                                    logger,
                                    &self._err,
                                    "server: persistence children remain unresolved after termination",
                                    error.PersistenceChildrenUnresolved,
                                );
                                self._unresolved_reported = true;
                            }
                            return .{ .status = .children_unresolved, .err = self._err };
                        }

                        recordError(
                            logger,
                            &self._err,
                            "server: persistence shutdown grace period expired",
                            error.PersistenceShutdownTimeout,
                        );
                        killChildren(logger, state, &self._err);

                        self._reap_deadline_ms = std.Io.Clock.awake.now(io).toMilliseconds() +| self._reap_ms;
                        continue;
                    }
                    io.sleep(.fromMilliseconds(@min(10, deadline -| now)), .awake) catch {};
                },
                .aof_unresolved => {
                    if (self._err == null) self._err = error.AofRewriteUnsettled;
                    return .{ .status = .aof_unresolved, .err = self._err };
                },
            }
        }
    }
};

/// Call after cron and all client workers have joined.
pub fn run(
    io: std.Io,
    logger: logging.Logger,
    state: *PersistenceState,
    maybe_aof: ?JournalPersistence,
) Result {
    return runWithOptions(io, logger, state, maybe_aof, .{});
}

pub fn runWithOptions(
    io: std.Io,
    logger: logging.Logger,
    state: *PersistenceState,
    maybe_aof: ?JournalPersistence,
    options: Options,
) Result {
    var context = Context.init(io, options);
    return context.run(io, logger, state, maybe_aof);
}

fn logChildren(logger: logging.Logger, state: *PersistenceState) void {
    var tx = state.beginUncancelable();
    const kgc = state.kgcShutdownState();
    const aof = state.aofShutdownState();
    tx.end();

    var buffer: [128]u8 = undefined;
    if (kgc == .child) logger.info(std.fmt.bufPrint(&buffer, "server: waiting for BGSAVE child pid {d} during shutdown", .{kgc.child.pid}) catch unreachable);
    if (aof == .child) logger.info(std.fmt.bufPrint(&buffer, "server: waiting for BGREWRITEAOF child pid {d} during shutdown", .{aof.child.pid}) catch unreachable);
}

fn killChildren(logger: logging.Logger, state: *PersistenceState, drain_error: *?anyerror) void {
    var tx = state.beginUncancelable();
    const kgc = state.kgcShutdownState();
    const aof = state.aofShutdownState();
    tx.end();

    const pids = [_]?std.posix.pid_t{
        if (kgc == .child) kgc.child.pid else null,
        if (aof == .child) aof.child.pid else null,
    };

    for (pids) |maybe_pid| {
        const pid = maybe_pid orelse continue;
        var buffer: [128]u8 = undefined;

        logger.info(std.fmt.bufPrint(&buffer, "server: terminating persistence child pid {d}", .{pid}) catch unreachable);
        state.killChild(pid) catch |err| {
            recordError(logger, drain_error, "server: failed to terminate persistence child", err);
        };
    }
}

const PollErrors = struct {
    kgc: bool = false,
    aof: bool = false,
};

fn drainOnce(
    io: std.Io,
    logger: logging.Logger,
    state: *PersistenceState,
    maybe_aof: ?JournalPersistence,
    drain_error: *?anyerror,
    poll_errors: *PollErrors,
) void {
    var state_tx = state.beginUncancelable();
    const kgc_state = state.kgcShutdownState();
    const aof_state = state.aofShutdownState();
    state_tx.end();

    switch (kgc_state) {
        .no_child => poll_errors.kgc = false,
        .child => {
            if (state.pollKgcShutdown(time.nowMs(io))) |result| {
                if (result.status != .running) {
                    finishKgc(io, logger, state, result, drain_error);
                    poll_errors.kgc = false;
                } else if (result.report_error) |err| {
                    if (!poll_errors.kgc) recordError(logger, drain_error, "server: failed to poll BGSAVE child", err);
                    poll_errors.kgc = true;
                }
            } else |err| {
                recordError(logger, drain_error, "server: failed to wait for BGSAVE child", err);
            }
        },
    }

    switch (aof_state) {
        .no_child => poll_errors.aof = false,
        .completed => |result| {
            finishAof(logger, state, maybe_aof, result, drain_error);
            poll_errors.aof = false;
        },
        .child => {
            if (state.pollAofShutdown()) |result| {
                if (result.status != .running) {
                    finishAof(logger, state, maybe_aof, result, drain_error);
                    poll_errors.aof = false;
                } else if (result.report_error) |err| {
                    if (!poll_errors.aof) recordError(logger, drain_error, "server: failed to poll BGREWRITEAOF child", err);
                    poll_errors.aof = true;
                }
            } else |err| {
                recordError(logger, drain_error, "server: failed to wait for BGREWRITEAOF child", err);
            }
        },
    }
}

fn finishKgc(
    io: std.Io,
    logger: logging.Logger,
    state: *PersistenceState,
    result: PersistenceState.KgcReapResult,
    drain_error: *?anyerror,
) void {
    if (result.report_error) |err| {
        logger.err("server: BGSAVE child failed", err, null);
        if (drain_error.* == null) drain_error.* = err;
    } else if (result.status == .failed) {
        logger.err("server: BGSAVE child failed", error.BackgroundSaveFailed, null);
        if (drain_error.* == null) drain_error.* = error.BackgroundSaveFailed;
    }

    var state_tx = state.beginUncancelable();
    defer state_tx.end();
    defer state.finishKgc();

    if (result.status == .succeeded) {
        state.markSaved(result.saved_change_count.?, time.nowMs(io)) catch |err| {
            recordError(logger, drain_error, "server: failed to account for BGSAVE", err);
        };
    }
}

fn finishAof(
    logger: logging.Logger,
    state: *PersistenceState,
    maybe_aof: ?JournalPersistence,
    result: PersistenceState.AofReapResult,
    drain_error: *?anyerror,
) void {
    const failure: ?anyerror = if (result.report_error) |err| err else if (result.status == .failed) error.AofRewriteFailed else null;
    if (failure) |err| {
        const should_report = blk: {
            var state_tx = state.beginUncancelable();
            defer state_tx.end();
            break :blk state.claimAofFailureReport();
        };
        if (should_report) logger.err("server: BGREWRITEAOF child failed", err, null);
        // Reporting in cron must not hide the failure from shutdown's caller.
        if (drain_error.* == null) drain_error.* = err;
    }

    const aof = maybe_aof orelse {
        recordError(logger, drain_error, "server: AOF rewrite has no backend", error.AofDisabled);
        return;
    };
    var journal_tx = aof.beginUncancelable();
    defer journal_tx.end();

    aof.finishRewrite(result.status) catch |err| {
        recordError(logger, drain_error, "server: failed to finish AOF rewrite", err);

        // Before manifest publication, the pending base still needs rollback.
        if (aof.getRewriteResolution() == .pending) {
            aof.finishRewrite(.failed) catch |rollback_err| {
                recordError(logger, drain_error, "server: failed to roll back AOF rewrite", rollback_err);
            };
        }
    };

    if (aof.getRewriteResolution() == .settled) {
        var state_tx = state.beginUncancelable();
        defer state_tx.end();
        state.finishAof();
    } else {
        recordError(logger, drain_error, "server: AOF rewrite remains unsettled", error.AofRewriteUnsettled);
    }
}

fn getShutdownState(state: *PersistenceState, maybe_aof: ?JournalPersistence) ShutdownState {
    const resolution: JournalPersistence.RewriteResolution = if (maybe_aof) |aof| blk: {
        var journal_tx = aof.beginUncancelable();
        defer journal_tx.end();
        break :blk aof.getRewriteResolution();
    } else .none;

    var state_tx = state.beginUncancelable();
    defer state_tx.end();

    switch (state.kgcShutdownState()) {
        .no_child => {},
        .child => return .child_tracked,
    }
    switch (state.aofShutdownState()) {
        .no_child => {},
        .child => return .child_tracked,
        .completed => return .aof_unresolved,
    }
    // A pending base without a tracked result has not been published or
    // rolled back, even though there is no child left to wait for.
    if (resolution == .pending) return .aof_unresolved;
    return .ready;
}

fn recordError(logger: logging.Logger, drain_error: *?anyerror, message: []const u8, err: anyerror) void {
    logger.err(message, err, @errorReturnTrace());
    if (drain_error.* == null) drain_error.* = err;
}

// Fake only the clock and sleep. No test depends on elapsed wall time.
const TestClock = struct {
    ms: i64 = 0,
    sleeps: usize = 0,
    vtable: std.Io.VTable = undefined,

    fn io(self: *TestClock) std.Io {
        self.vtable = std.testing.io.vtable.*;
        self.vtable.now = now;
        self.vtable.sleep = sleep;
        return .{ .userdata = self, .vtable = &self.vtable };
    }

    fn now(userdata: ?*anyopaque, clock: std.Io.Clock) std.Io.Timestamp {
        const self: *TestClock = @ptrCast(@alignCast(userdata));
        // Moving real time backwards must not affect the shutdown budget.
        return .{ .nanoseconds = @as(i96, if (clock == .awake) self.ms else -self.ms) * std.time.ns_per_ms };
    }

    fn sleep(userdata: ?*anyopaque, timeout: std.Io.Timeout) std.Io.Cancelable!void {
        const self: *TestClock = @ptrCast(@alignCast(userdata));
        self.ms +|= timeout.duration.raw.toMilliseconds();
        self.sleeps += 1;
    }
};

test "shutdown polls both children and settles completed work before the shared deadline" {
    const Fake = struct {
        var kgc_calls: usize = 0;
        var aof_calls: usize = 0;
        fn wait(pid: std.posix.pid_t) anyerror!?u32 {
            if (pid == 101) {
                kgc_calls += 1;
                return if (kgc_calls == 3) 0 else null;
            }
            aof_calls += 1;
            return 0;
        }
        fn kill(_: std.posix.pid_t) anyerror!void {
            return error.UnexpectedKill;
        }
    };
    Fake.kgc_calls = 0;
    Fake.aof_calls = 0;
    var clock: TestClock = .{};
    var state = PersistenceState.init(std.testing.io, .{ .mutual_exclusive = false, .process = .{ .wait_pid = Fake.wait, .kill_pid = Fake.kill } });
    state.setInFlightKgcSave(.{ .pid = 101, .captured_change_count = 0, .origin = .manual });
    // AOF can exit before KGC even though KGC is polled first.
    state.setInFlightAofRewrite(.{ .pid = 102, .base_seq = 2, .origin = .manual });
    var logger = logging.TestLogger.init();
    // No AOF backend deliberately leaves rewrite settlement unresolved. The
    // KGC child must still be polled to completion before returning that state.
    const result = runWithOptions(clock.io(), logger.logger(), &state, null, .{ .grace_ms = 30 });
    try std.testing.expectEqual(Status.aof_unresolved, result.status);
    try std.testing.expectEqual(error.AofDisabled, result.err.?);
    try std.testing.expectEqual(3, Fake.kgc_calls);
    try std.testing.expectEqual(1, Fake.aof_calls);
    try std.testing.expectEqual(2, clock.sleeps);
    try std.testing.expect(state.kgcShutdownState() == .no_child);
}

test "shutdown bounds stuck children and wait errors without forgetting their PIDs" {
    const Fake = struct {
        var failure: bool = false;
        var killed: [2]bool = .{ false, false };
        var kills: usize = 0;
        fn wait(_: std.posix.pid_t) anyerror!?u32 {
            if (failure) return error.Unexpected;
            return null;
        }
        fn kill(pid: std.posix.pid_t) anyerror!void {
            killed[@intCast(pid - 101)] = true;
            kills += 1;
            if (failure) return error.PermissionDenied;
        }
    };
    for ([_]bool{ false, true }) |failure| {
        Fake.failure = failure;
        Fake.killed = .{ false, false };
        Fake.kills = 0;
        var clock: TestClock = .{};
        var state = PersistenceState.init(std.testing.io, .{ .mutual_exclusive = false, .process = .{ .wait_pid = Fake.wait, .kill_pid = Fake.kill } });
        state.setInFlightKgcSave(.{ .pid = 101, .captured_change_count = 0, .origin = .manual });
        state.setInFlightAofRewrite(.{ .pid = 102, .base_seq = 2, .origin = .manual });
        var logger = logging.TestLogger.init();
        const result = runWithOptions(clock.io(), logger.logger(), &state, null, .{ .grace_ms = 20, .reap_ms = 20 });
        try std.testing.expectEqual(Status.children_unresolved, result.status);
        try std.testing.expectEqual(if (failure) error.Unexpected else error.PersistenceShutdownTimeout, result.err.?);
        try std.testing.expectEqual(40, clock.ms);
        try std.testing.expectEqual(2, Fake.kills);
        try std.testing.expect(Fake.killed[0] and Fake.killed[1]);
        try std.testing.expect(state.kgcShutdownState() == .child);
        try std.testing.expect(state.aofShutdownState() == .child);
    }
}

test "zero grace signals a running child once and reaps it through the normal failure path" {
    const Fake = struct {
        var killed: bool = false;
        fn wait(_: std.posix.pid_t) anyerror!?u32 {
            return if (killed) 9 else null;
        }
        fn kill(_: std.posix.pid_t) anyerror!void {
            try std.testing.expect(!killed);
            killed = true;
        }
    };
    Fake.killed = false;
    var clock: TestClock = .{};
    var state = PersistenceState.init(std.testing.io, .{ .mutual_exclusive = false, .process = .{ .wait_pid = Fake.wait, .kill_pid = Fake.kill } });
    _ = state.tryStartKgc(.immediate);
    state.setInFlightKgcSave(.{ .pid = 101, .captured_change_count = 10, .origin = .manual });
    var logger = logging.TestLogger.init();
    const result = runWithOptions(clock.io(), logger.logger(), &state, null, .{ .grace_ms = 0 });
    try std.testing.expectEqual(Status.complete, result.status);
    try std.testing.expectEqual(error.PersistenceShutdownTimeout, result.err.?);
    try std.testing.expectEqual(0, clock.sleeps);
    try std.testing.expect(state.kgcShutdownState() == .no_child);
    try std.testing.expect(!state.kgcInProgress());
}

test "zero grace collects an already exited child without signalling it" {
    const Fake = struct {
        fn wait(_: std.posix.pid_t) anyerror!?u32 {
            return 0;
        }
        fn kill(_: std.posix.pid_t) anyerror!void {
            return error.UnexpectedKill;
        }
    };
    var clock: TestClock = .{};
    var state = PersistenceState.init(std.testing.io, .{ .mutual_exclusive = false, .process = .{ .wait_pid = Fake.wait, .kill_pid = Fake.kill } });
    _ = state.tryStartKgc(.immediate);
    state.setInFlightKgcSave(.{ .pid = 101, .captured_change_count = 0, .origin = .manual });
    var logger = logging.TestLogger.init();
    const result = runWithOptions(clock.io(), logger.logger(), &state, null, .{ .grace_ms = 0 });
    try std.testing.expectEqual(Status.complete, result.status);
    try std.testing.expectEqual(null, result.err);
    try std.testing.expectEqual(0, clock.sleeps);
    try std.testing.expect(!state.kgcInProgress());
}

test "successive drains share the deadline and keep the first error" {
    const testing = std.testing;
    const Fake = struct {
        var clock: *TestClock = undefined;
        var first_calls: usize = 0;
        var kill_at: ?i64 = null;

        fn wait(pid: std.posix.pid_t) anyerror!?u32 {
            if (pid == 101) {
                first_calls += 1;
                return switch (first_calls) {
                    1 => error.Unexpected,
                    2 => null,
                    else => 0,
                };
            }
            if (pid == 102) return 0;
            return if (kill_at != null) 9 else null;
        }

        fn kill(pid: std.posix.pid_t) anyerror!void {
            if (pid != 103 or kill_at != null) return error.UnexpectedKill;
            kill_at = clock.ms;
        }
    };
    var clock: TestClock = .{};
    Fake.clock = &clock;
    Fake.first_calls = 0;
    Fake.kill_at = null;
    const io = clock.io();
    var context = Context.init(io, .{ .grace_ms = 40, .reap_ms = 20 });
    var state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false, .process = .{ .wait_pid = Fake.wait, .kill_pid = Fake.kill } });
    var logger = logging.TestLogger.init();

    state.setInFlightKgcSave(.{ .pid = 101, .captured_change_count = 0, .origin = .manual });
    const first = context.run(io, logger.logger(), &state, null);
    try testing.expectEqual(Status.complete, first.status);
    try testing.expectEqual(error.Unexpected, first.err.?);
    try testing.expectEqual(20, clock.ms);
    try testing.expectEqual(20, context.remainingMs(io));
    try testing.expectEqual(3, Fake.first_calls);

    state.setInFlightKgcSave(.{ .pid = 102, .captured_change_count = 0, .origin = .manual });
    const second = context.run(io, logger.logger(), &state, null);
    try testing.expectEqual(Status.complete, second.status);
    try testing.expectEqual(error.Unexpected, second.err.?);
    try testing.expectEqual(20, context.remainingMs(io));

    // Time spent between drain calls also uses the original budget.
    clock.ms += 5;
    try testing.expectEqual(15, context.remainingMs(io));
    state.setInFlightKgcSave(.{ .pid = 103, .captured_change_count = 0, .origin = .manual });
    const third = context.run(io, logger.logger(), &state, null);
    try testing.expectEqual(Status.complete, third.status);
    try testing.expectEqual(error.Unexpected, third.err.?);
    try testing.expectEqual(40, Fake.kill_at.?);
    try testing.expectEqual(40, clock.ms);
    try testing.expectEqual(0, context.remainingMs(io));
    try testing.expect(state.kgcShutdownState() == .no_child);
}

test "repeated drains keep the reap deadline and report errors once" {
    const testing = std.testing;
    const Fake = struct {
        var kills: usize = 0;

        fn wait(_: std.posix.pid_t) anyerror!?u32 {
            return error.Unexpected;
        }

        fn kill(_: std.posix.pid_t) anyerror!void {
            kills += 1;
        }
    };
    Fake.kills = 0;
    var clock: TestClock = .{};
    const io = clock.io();
    var context = Context.init(io, .{ .grace_ms = 0, .reap_ms = 20 });
    var state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false, .process = .{ .wait_pid = Fake.wait, .kill_pid = Fake.kill } });
    state.setInFlightKgcSave(.{ .pid = 101, .captured_change_count = 0, .origin = .manual });
    var logger = logging.TestLogger.init();

    for (0..2) |_| {
        const result = context.run(io, logger.logger(), &state, null);
        try testing.expectEqual(Status.children_unresolved, result.status);
        try testing.expectEqual(error.Unexpected, result.err.?);
        try testing.expectEqual(20, clock.ms);
        try testing.expectEqual(2, clock.sleeps);
        try testing.expectEqual(1, Fake.kills);
        try testing.expectEqual(0, context.remainingMs(io));
        try testing.expect(state.kgcShutdownState() == .child);
    }

    var errors: usize = 0;
    for (logger.recordedEvents()) |event| {
        if (event.kind == .err) errors += 1;
    }
    // One poll error, one timeout, and one unresolved-child report.
    try testing.expectEqual(3, errors);
}

test "a shared context reports polling failures for each new child" {
    const testing = std.testing;
    const Fake = struct {
        var calls: usize = 0;

        fn wait(_: std.posix.pid_t) anyerror!?u32 {
            calls += 1;
            return if (calls % 2 == 1) error.Unexpected else 0;
        }

        fn kill(_: std.posix.pid_t) anyerror!void {
            return error.UnexpectedKill;
        }
    };
    Fake.calls = 0;
    var clock: TestClock = .{};
    const io = clock.io();
    var context = Context.init(io, .{ .grace_ms = 100 });
    var state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false, .process = .{ .wait_pid = Fake.wait, .kill_pid = Fake.kill } });
    var logger = logging.TestLogger.init();

    for ([_]std.posix.pid_t{ 101, 102 }) |pid| {
        state.setInFlightKgcSave(.{ .pid = pid, .captured_change_count = 0, .origin = .manual });
        const result = context.run(io, logger.logger(), &state, null);
        try testing.expectEqual(Status.complete, result.status);
        try testing.expectEqual(error.Unexpected, result.err.?);
    }

    var errors: usize = 0;
    for (logger.recordedEvents()) |event| {
        if (event.kind == .err) {
            try testing.expectEqual(error.Unexpected, event.source.?);
            errors += 1;
        }
    }
    try testing.expectEqual(2, errors);
    try testing.expectEqual(4, Fake.calls);
    try testing.expectEqual(80, context.remainingMs(io));
}

test "idle drains return promptly without refreshing an expired budget" {
    const testing = std.testing;
    var clock: TestClock = .{};
    const io = clock.io();
    var context = Context.init(io, .{ .grace_ms = 20 });
    var state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });
    var logger = logging.TestLogger.init();

    clock.ms = 7;
    const first = context.run(io, logger.logger(), &state, null);
    try testing.expectEqual(Status.complete, first.status);
    try testing.expectEqual(null, first.err);
    try testing.expectEqual(13, context.remainingMs(io));

    clock.ms = 20;
    const second = context.run(io, logger.logger(), &state, null);
    try testing.expectEqual(Status.complete, second.status);
    try testing.expectEqual(null, second.err);
    try testing.expectEqual(0, context.remainingMs(io));
    try testing.expectEqual(0, clock.sleeps);
    try testing.expectEqual(0, logger.recordedEvents().len);
}

test "shutdown deadline arithmetic saturates and polling stays within the time left" {
    const testing = std.testing;
    const Fake = struct {
        var kills: usize = 0;

        fn wait(_: std.posix.pid_t) anyerror!?u32 {
            return null;
        }

        fn kill(_: std.posix.pid_t) anyerror!void {
            kills += 1;
        }
    };
    Fake.kills = 0;
    var clock: TestClock = .{ .ms = std.math.maxInt(i64) - 2 };
    const io = clock.io();
    var context = Context.init(io, .{
        .grace_ms = std.math.maxInt(u32),
        .reap_ms = std.math.maxInt(u32),
    });
    var state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false, .process = .{ .wait_pid = Fake.wait, .kill_pid = Fake.kill } });
    state.setInFlightKgcSave(.{ .pid = 101, .captured_change_count = 0, .origin = .manual });
    var logger = logging.TestLogger.init();

    try testing.expectEqual(2, context.remainingMs(io));
    const result = context.run(io, logger.logger(), &state, null);
    try testing.expectEqual(Status.children_unresolved, result.status);
    try testing.expectEqual(error.PersistenceShutdownTimeout, result.err.?);
    try testing.expectEqual(std.math.maxInt(i64), clock.ms);
    try testing.expectEqual(1, clock.sleeps);
    try testing.expectEqual(1, Fake.kills);
    try testing.expectEqual(0, context.remainingMs(io));
    try testing.expect(state.kgcShutdownState() == .child);
}
