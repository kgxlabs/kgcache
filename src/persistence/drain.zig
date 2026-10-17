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
    var drain_error: ?anyerror = null;
    var deadline = std.Io.Clock.awake.now(io).toMilliseconds() + options.grace_ms;
    var terminating = false;
    var poll_errors: PollErrors = .{};
    // TODO: replace this with proper logger after this issue: https://github.com/kgxlabs/kgcache/issues/227
    logChildren(logger, state);

    while (true) {
        drainOnce(io, logger, state, maybe_aof, &drain_error, &poll_errors);

        switch (getShutdownState(state, maybe_aof)) {
            .ready => return .{ .status = .complete, .err = drain_error },
            .child_tracked => {
                const now = std.Io.Clock.awake.now(io).toMilliseconds();
                if (now >= deadline) {
                    if (terminating) {
                        recordError(logger, &drain_error, "server: persistence children remain unresolved after termination", error.PersistenceChildrenUnresolved);
                        return .{ .status = .children_unresolved, .err = drain_error };
                    }

                    recordError(
                        logger,
                        &drain_error,
                        "server: persistence shutdown grace period expired",
                        error.PersistenceShutdownTimeout,
                    );
                    killChildren(logger, state, &drain_error);

                    terminating = true;
                    deadline = std.Io.Clock.awake.now(io).toMilliseconds() + options.reap_ms;
                    continue;
                }
                io.sleep(.fromMilliseconds(@intCast(@min(10, deadline - now))), .awake) catch {};
            },
            .aof_unresolved => return .{
                .status = .aof_unresolved,
                .err = drain_error orelse error.AofRewriteUnsettled,
            },
        }
    }
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
        .no_child => {},
        .child => {
            if (state.pollKgcShutdown(time.nowMs(io))) |result| {
                if (result.status != .running) finishKgc(io, logger, state, result, drain_error) else if (result.report_error) |err| {
                    if (!poll_errors.kgc) recordError(logger, drain_error, "server: failed to poll BGSAVE child", err);
                    poll_errors.kgc = true;
                }
            } else |err| {
                recordError(logger, drain_error, "server: failed to wait for BGSAVE child", err);
            }
        },
    }

    switch (aof_state) {
        .no_child => {},
        .completed => |result| finishAof(logger, state, maybe_aof, result, drain_error),
        .child => {
            if (state.pollAofShutdown()) |result| {
                if (result.status != .running) finishAof(logger, state, maybe_aof, result, drain_error) else if (result.report_error) |err| {
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

    fn sleep(userdata: ?*anyopaque, _: std.Io.Timeout) std.Io.Cancelable!void {
        const self: *TestClock = @ptrCast(@alignCast(userdata));
        self.ms += 10;
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
