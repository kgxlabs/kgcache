const std = @import("std");
const time = @import("time.zig");
const Config = @import("config.zig");
const PersistenceState = @import("persistence_state.zig");
const StartPolicy = PersistenceState.StartPolicy;
const StartDecision = PersistenceState.StartDecision;
const ReapResult = PersistenceState.ReapResult;
const KgcReapResult = PersistenceState.KgcReapResult;

test "ending a PersistenceState session allows another session to begin" {
    const testing = std.testing;
    var state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });

    var first = try state.begin();
    first.end();

    var second = try state.begin();
    second.end();
}

test "PersistenceState begin serializes two concurrent callers" {
    const testing = std.testing;
    const Context = struct {
        state: *PersistenceState,
        attempting: std.atomic.Value(bool) = .init(false),
        entered: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            self.attempting.store(true, .release);
            var tx = self.state.begin() catch unreachable;
            self.entered.store(true, .release);
            tx.end();
        }
    };

    var state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });
    var first = try state.begin();
    var context: Context = .{ .state = &state };
    const thread = try std.Thread.spawn(.{}, Context.run, .{&context});

    while (!context.attempting.load(.acquire)) std.atomic.spinLoopHint();
    try testing.expect(!context.entered.load(.acquire));

    first.end();
    thread.join();
    try testing.expect(context.entered.load(.acquire));
}

test "tryStartKgc blocks a second start until finishKgc releases it" {
    const testing = std.testing;
    var state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });

    {
        var tx = try state.begin();
        defer tx.end();
        try testing.expectEqual(PersistenceState.StartDecision.started, state.tryStartKgc(.immediate));
    }
    {
        var tx = try state.begin();
        defer tx.end();
        try testing.expectEqual(PersistenceState.StartDecision.busy, state.tryStartKgc(.immediate));
    }
    {
        var tx = try state.begin();
        defer tx.end();
        state.finishKgc();
    }
    {
        var tx = try state.begin();
        defer tx.end();
        try testing.expectEqual(PersistenceState.StartDecision.started, state.tryStartKgc(.immediate));
    }
}

test "bgsave cooldown uses the failure time and clears explicitly" {
    const testing = std.testing;
    var state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });
    var tx = try state.begin();
    defer tx.end();
    const failure_ms = time.nowMs(testing.io);

    try testing.expect(state.bgsaveCooldownElapsed(failure_ms, 500));

    state.startBgsaveCooldown(failure_ms);
    try testing.expect(!state.bgsaveCooldownElapsed(failure_ms + 499, 500));
    try testing.expect(state.bgsaveCooldownElapsed(failure_ms + 500, 500));
    try testing.expect(state.bgsaveCooldownElapsed(failure_ms, 0));
    try testing.expect(!state.bgsaveCooldownElapsed(failure_ms - 1, 500));

    state.clearBgsaveCooldown();
    try testing.expect(state.bgsaveCooldownElapsed(failure_ms - 1, 500));
}

test "tryStartAof blocks a second start until finishAof releases it" {
    const testing = std.testing;
    var state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });

    {
        var tx = try state.begin();
        defer tx.end();
        try testing.expectEqual(PersistenceState.StartDecision.started, state.tryStartAof(.immediate));
    }
    {
        var tx = try state.begin();
        defer tx.end();
        try testing.expectEqual(PersistenceState.StartDecision.busy, state.tryStartAof(.immediate));
    }
    {
        var tx = try state.begin();
        defer tx.end();
        state.finishAof();
    }
    {
        var tx = try state.begin();
        defer tx.end();
        try testing.expectEqual(PersistenceState.StartDecision.started, state.tryStartAof(.immediate));
    }
}

test "mutual exclusion blocks kgc while aof is in progress" {
    const testing = std.testing;
    var state = PersistenceState.init(testing.io, .{ .mutual_exclusive = true });

    {
        var tx = try state.begin();
        defer tx.end();
        try testing.expectEqual(PersistenceState.StartDecision.started, state.tryStartAof(.immediate));
    }
    {
        var tx = try state.begin();
        defer tx.end();
        try testing.expectEqual(PersistenceState.StartDecision.busy, state.tryStartKgc(.immediate));
    }
    {
        var tx = try state.begin();
        defer tx.end();
        state.finishAof();
    }
    {
        var tx = try state.begin();
        defer tx.end();
        try testing.expectEqual(PersistenceState.StartDecision.started, state.tryStartKgc(.immediate));
    }

    var final = try state.begin();
    final.end();
}

test "mutual exclusion blocks aof while kgc is in progress" {
    const testing = std.testing;
    var state = PersistenceState.init(testing.io, .{ .mutual_exclusive = true });

    {
        var tx = try state.begin();
        defer tx.end();
        try testing.expectEqual(PersistenceState.StartDecision.started, state.tryStartKgc(.immediate));
    }
    {
        var tx = try state.begin();
        defer tx.end();
        try testing.expectEqual(PersistenceState.StartDecision.busy, state.tryStartAof(.immediate));
    }
    {
        var tx = try state.begin();
        defer tx.end();
        state.finishKgc();
    }
    {
        var tx = try state.begin();
        defer tx.end();
        try testing.expectEqual(PersistenceState.StartDecision.started, state.tryStartAof(.immediate));
    }

    var final = try state.begin();
    final.end();
}

test "without mutual exclusion kgc and aof can be in progress at the same time" {
    const testing = std.testing;
    var state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });

    {
        var tx = try state.begin();
        defer tx.end();
        try testing.expectEqual(PersistenceState.StartDecision.started, state.tryStartKgc(.immediate));
    }
    {
        var tx = try state.begin();
        defer tx.end();
        try testing.expectEqual(PersistenceState.StartDecision.started, state.tryStartAof(.immediate));
    }

    var final = try state.begin();
    final.end();
}

test "background start decisions reserve and restore pending work" {
    const testing = std.testing;
    const Kind = enum { kgc, aof };
    const Case = struct {
        exclusive: bool,
        active: ?Kind,
        requested: Kind,
        policy: StartPolicy,
        expected: StartDecision,
    };
    const cases = [_]Case{
        .{ .exclusive = true, .active = null, .requested = .kgc, .policy = .immediate, .expected = .started },
        .{ .exclusive = true, .active = null, .requested = .aof, .policy = .schedule, .expected = .started },
        .{ .exclusive = true, .active = .kgc, .requested = .kgc, .policy = .schedule, .expected = .busy },
        .{ .exclusive = true, .active = .aof, .requested = .aof, .policy = .schedule, .expected = .busy },
        .{ .exclusive = true, .active = .kgc, .requested = .aof, .policy = .immediate, .expected = .busy },
        .{ .exclusive = true, .active = .aof, .requested = .kgc, .policy = .immediate, .expected = .busy },
        .{ .exclusive = true, .active = .kgc, .requested = .aof, .policy = .schedule, .expected = .scheduled },
        .{ .exclusive = true, .active = .aof, .requested = .kgc, .policy = .schedule, .expected = .scheduled },
        .{ .exclusive = false, .active = .kgc, .requested = .aof, .policy = .schedule, .expected = .started },
        .{ .exclusive = false, .active = .aof, .requested = .kgc, .policy = .schedule, .expected = .started },
        .{ .exclusive = false, .active = .kgc, .requested = .kgc, .policy = .schedule, .expected = .busy },
        .{ .exclusive = false, .active = .aof, .requested = .aof, .policy = .schedule, .expected = .busy },
    };

    for (cases) |case| {
        var state = PersistenceState.init(testing.io, .{ .mutual_exclusive = case.exclusive });
        var tx = try state.begin();
        defer tx.end();

        if (case.active) |active| {
            const first = switch (active) {
                .kgc => state.tryStartKgc(.immediate),
                .aof => state.tryStartAof(.immediate),
            };
            try testing.expectEqual(StartDecision.started, first);
        }

        const decision = switch (case.requested) {
            .kgc => state.tryStartKgc(case.policy),
            .aof => state.tryStartAof(case.policy),
        };
        try testing.expectEqual(case.expected, decision);

        const pending = switch (case.requested) {
            .kgc => state._pending_kgc,
            .aof => state._pending_aof,
        };
        const expected_pending = decision == .scheduled;
        try testing.expectEqual(expected_pending, pending);
    }

    const FakeWaitPid = struct {
        fn succeeded(_: std.posix.pid_t) anyerror!?u32 {
            return 0;
        }
    };

    for ([_]Kind{ .kgc, .aof }) |requested| {
        const blocker: Kind = if (requested == .kgc) .aof else .kgc;
        var state = PersistenceState.init(testing.io, .{
            .mutual_exclusive = true,
            .process = .{ .wait_pid = FakeWaitPid.succeeded },
        });
        var tx = try state.begin();
        defer tx.end();

        switch (blocker) {
            .kgc => {
                try testing.expectEqual(StartDecision.started, state.tryStartKgc(.immediate));
                state.setInFlightKgcSave(.{ .pid = 11, .captured_change_count = 0, .origin = .manual });
            },
            .aof => {
                try testing.expectEqual(StartDecision.started, state.tryStartAof(.immediate));
                state.setInFlightAofRewrite(.{ .pid = 11, .base_seq = 1, .origin = .manual });
            },
        }

        const scheduled = switch (requested) {
            .kgc => state.tryStartKgc(.schedule),
            .aof => state.tryStartAof(.schedule),
        };
        try testing.expectEqual(StartDecision.scheduled, scheduled);
        const repeated = switch (requested) {
            .kgc => state.tryStartKgc(.schedule),
            .aof => state.tryStartAof(.schedule),
        };
        try testing.expectEqual(StartDecision.scheduled, repeated);
        const immediate_while_pending = switch (requested) {
            .kgc => state.tryStartKgc(.immediate),
            .aof => state.tryStartAof(.immediate),
        };
        try testing.expectEqual(StartDecision.busy, immediate_while_pending);
        try testing.expect(if (requested == .kgc) state._pending_kgc else state._pending_aof);
        try testing.expect(!(if (requested == .kgc) state.claimPendingKgc() else state.claimPendingAof()));

        switch (blocker) {
            .kgc => {
                try testing.expectEqual(ReapResult.succeeded, state.reapKgc(time.nowMs(testing.io)).status);
                state.finishKgc();
            },
            .aof => {
                try testing.expectEqual(ReapResult.succeeded, state.reapAof().status);
                try testing.expect(state.aofInProgress());
                try testing.expectEqual(ReapResult.succeeded, state.reapAof().status);
                state.finishAof();
            },
        }

        const blocked_by_reservation = switch (blocker) {
            .kgc => state.tryStartKgc(.immediate),
            .aof => state.tryStartAof(.immediate),
        };
        try testing.expectEqual(StartDecision.busy, blocked_by_reservation);
        const queued_behind_reservation = switch (blocker) {
            .kgc => state.tryStartKgc(.schedule),
            .aof => state.tryStartAof(.schedule),
        };
        try testing.expectEqual(StartDecision.scheduled, queued_behind_reservation);

        if (requested == .kgc) {
            try testing.expectError(error.InvalidPendingClaim, state.failPendingKgcStart());
            try testing.expectError(error.InvalidPendingClaim, state.completePendingKgcStart(.{
                .pid = 99,
                .captured_change_count = 0,
                .origin = .manual,
            }));
            try testing.expect(state._in_flight_kgc_save == null);
        } else {
            try testing.expectError(error.InvalidPendingClaim, state.failPendingAofStart());
            try testing.expectError(error.InvalidPendingClaim, state.completePendingAofStart(.{
                .pid = 99,
                .base_seq = 1,
                .origin = .manual,
            }));
            try testing.expect(state._in_flight_aof_rewrite == null);
        }
        try testing.expect(if (requested == .kgc) state._pending_kgc else state._pending_aof);
        try testing.expect(if (requested == .kgc) state.claimPendingKgc() else state.claimPendingAof());
        try testing.expect(!(if (requested == .kgc) state.claimPendingKgc() else state.claimPendingAof()));
        try testing.expect(if (requested == .kgc) state._pending_kgc else state._pending_aof);
        const repeated_while_launching = switch (requested) {
            .kgc => state.tryStartKgc(.schedule),
            .aof => state.tryStartAof(.schedule),
        };
        try testing.expectEqual(StartDecision.scheduled, repeated_while_launching);

        if (requested == .kgc) try state.failPendingKgcStart() else try state.failPendingAofStart();
        try testing.expect(if (requested == .kgc) state._pending_kgc else state._pending_aof);
        try testing.expect(if (requested == .kgc) state.claimPendingKgc() else state.claimPendingAof());

        switch (requested) {
            .kgc => {
                try state.completePendingKgcStart(.{ .pid = 12, .captured_change_count = 0, .origin = .manual });
                try testing.expect(!state._pending_kgc);
            },
            .aof => {
                try state.completePendingAofStart(.{ .pid = 12, .base_seq = 2, .origin = .manual });
                try testing.expect(!state._pending_aof);
            },
        }
        try testing.expect(!(if (blocker == .kgc) state.claimPendingKgc() else state.claimPendingAof()));

        switch (requested) {
            .kgc => {
                try testing.expectEqual(ReapResult.succeeded, state.reapKgc(time.nowMs(testing.io)).status);
                state.finishKgc();
            },
            .aof => {
                try testing.expectEqual(ReapResult.succeeded, state.reapAof().status);
                state.finishAof();
            },
        }
        try testing.expect(if (blocker == .kgc) state.claimPendingKgc() else state.claimPendingAof());
    }
}

test "invalid pending completion leaves state unchanged" {
    const testing = std.testing;
    const FakeWaitPid = struct {
        fn succeeded(_: std.posix.pid_t) anyerror!?u32 {
            return 0;
        }
    };

    for ([_]enum { kgc, aof }{ .kgc, .aof }) |kind| {
        var state = PersistenceState.init(testing.io, .{
            .mutual_exclusive = true,
            .process = .{ .wait_pid = FakeWaitPid.succeeded },
        });
        var tx = try state.begin();
        defer tx.end();

        switch (kind) {
            .kgc => {
                try testing.expectError(error.InvalidPendingClaim, state.failPendingKgcStart());
                try testing.expectError(error.InvalidPendingClaim, state.completePendingKgcStart(.{
                    .pid = 21,
                    .captured_change_count = 0,
                    .origin = .manual,
                }));
                try testing.expect(!state.kgcInProgress());
                try testing.expect(!state._pending_kgc);
                try testing.expect(state._in_flight_kgc_save == null);

                try testing.expectEqual(StartDecision.started, state.tryStartKgc(.immediate));
                state.setInFlightKgcSave(.{ .pid = 21, .captured_change_count = 0, .origin = .manual });
                try testing.expectError(error.ChildAlreadyTracked, state.completePendingKgcStart(.{
                    .pid = 23,
                    .captured_change_count = 0,
                    .origin = .manual,
                }));
                try testing.expectEqual(@as(std.posix.pid_t, 21), state._in_flight_kgc_save.?.pid);
                try testing.expectError(error.ChildAlreadyTracked, state.failPendingKgcStart());
                try testing.expectEqual(ReapResult.succeeded, state.reapKgc(time.nowMs(testing.io)).status);
                state.finishKgc();
                try testing.expect(!state.kgcInProgress());
            },
            .aof => {
                try testing.expectError(error.InvalidPendingClaim, state.failPendingAofStart());
                try testing.expectError(error.InvalidPendingClaim, state.completePendingAofStart(.{
                    .pid = 22,
                    .base_seq = 1,
                    .origin = .manual,
                }));
                try testing.expect(!state.aofInProgress());
                try testing.expect(!state._pending_aof);
                try testing.expect(state._in_flight_aof_rewrite == null);

                try testing.expectEqual(StartDecision.started, state.tryStartAof(.immediate));
                state.setInFlightAofRewrite(.{ .pid = 22, .base_seq = 1, .origin = .manual });
                try testing.expectError(error.ChildAlreadyTracked, state.completePendingAofStart(.{
                    .pid = 24,
                    .base_seq = 2,
                    .origin = .manual,
                }));
                try testing.expectEqual(@as(std.posix.pid_t, 22), state._in_flight_aof_rewrite.?.pid);
                try testing.expectError(error.ChildAlreadyTracked, state.failPendingAofStart());
                try testing.expectEqual(ReapResult.succeeded, state.reapAof().status);
                state.finishAof();
                try testing.expect(!state.aofInProgress());
            },
        }
    }
}

test "reapKgc reports running until background save completes" {
    const testing = std.testing;
    var state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });
    {
        var tx = try state.begin();
        defer tx.end();
        try testing.expectEqual(PersistenceState.StartDecision.started, state.tryStartKgc(.immediate));
    }

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
    const failure_ms = time.nowMs(testing.io);
    {
        var tx = try state.begin();
        defer tx.end();
        state.startBgsaveCooldown(failure_ms);
        state.setInFlightKgcSave(.{ .pid = pid, .captured_change_count = 17, .origin = .manual });
    }
    {
        var tx = try state.begin();
        defer tx.end();
        try testing.expectEqual(ReapResult.running, state.reapKgc(failure_ms).status);
        try testing.expect(state.kgcInProgress());
    }

    var byte: [1]u8 = .{1};
    _ = std.c.write(fds[1], &byte, 1);
    _ = std.c.close(fds[1]);

    var result: KgcReapResult = .{ .status = .running };
    var tries: usize = 0;
    while (result.status == .running) {
        var tx = try state.begin();
        result = state.reapKgc(failure_ms);
        if (result.status != .running) {
            try testing.expect(state.kgcInProgress());
            try testing.expectEqual(PersistenceState.StartDecision.busy, state.tryStartKgc(.immediate));
            state.finishKgc();
        }
        tx.end();
        tries += 1;
        if (tries > 10_000) return error.ChildNeverReaped;
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    try testing.expectEqual(ReapResult.succeeded, result.status);
    try testing.expectEqual(17, result.saved_change_count.?);
    {
        var tx = try state.begin();
        defer tx.end();
        try testing.expect(!state.kgcInProgress());
        try testing.expect(state.bgsaveCooldownElapsed(failure_ms, 5000));
    }
}

test "waitpid source reaches the parent reaper without reading status" {
    const testing = std.testing;
    const FakeWaitPid = struct {
        fn wait(_: std.posix.pid_t) anyerror!?u32 {
            return error.NoChildProcess;
        }
    };

    var state = PersistenceState.init(testing.io, .{
        .mutual_exclusive = false,
        .process = .{ .wait_pid = FakeWaitPid.wait },
    });
    {
        var tx = try state.begin();
        defer tx.end();
        try testing.expectEqual(PersistenceState.StartDecision.started, state.tryStartKgc(.immediate));
        state.setInFlightKgcSave(.{ .pid = 123, .captured_change_count = 1, .origin = .manual });
        const result = state.reapKgc(time.nowMs(testing.io));
        try testing.expectEqual(ReapResult.failed, result.status);
        try testing.expectEqual(error.NoChildProcess, result.report_error.?);
        try testing.expect(result.saved_change_count == null);
    }
}

test "failed manual background save preserves cooldown and allows a later save" {
    const testing = std.testing;
    var state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });
    const retry_delay_ms = 5000;
    const failure_ms = time.nowMs(testing.io) - retry_delay_ms;
    {
        var tx = try state.begin();
        defer tx.end();
        try testing.expectEqual(PersistenceState.StartDecision.started, state.tryStartKgc(.immediate));
        state.startBgsaveCooldown(failure_ms);
    }

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
    {
        var tx = try state.begin();
        defer tx.end();
        state.setInFlightKgcSave(.{ .pid = pid, .captured_change_count = 23, .origin = .manual });
    }

    const reap_ms = failure_ms + 100;
    var result: KgcReapResult = .{ .status = .running };
    var tries: usize = 0;
    while (result.status == .running) {
        var tx = try state.begin();
        result = state.reapKgc(reap_ms);
        if (result.status != .running) state.finishKgc();
        tx.end();
        tries += 1;
        if (tries > 10_000) return error.ChildNeverReaped;
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    try testing.expectEqual(ReapResult.failed, result.status);
    try testing.expectEqual(error.ChildExitedAbnormally, result.report_error.?);
    try testing.expect(result.saved_change_count == null);
    {
        var tx = try state.begin();
        defer tx.end();
        try testing.expect(!state.bgsaveCooldownElapsed(failure_ms, retry_delay_ms));
        try testing.expect(state.bgsaveCooldownElapsed(failure_ms + retry_delay_ms, retry_delay_ms));
        try testing.expectEqual(PersistenceState.StartDecision.started, state.tryStartKgc(.immediate));
    }
}

test "dueForSave is false with no rules configured" {
    const testing = std.testing;
    var state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });

    state.recordChange();
    try testing.expect(!state.dueForSave(time.nowMs(testing.io), &.{}));
}

test "dueForSave is false before the seconds threshold elapses even with enough changes" {
    const testing = std.testing;
    var state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });

    for (0..100) |_| state.recordChange();

    const rules = [_]Config.SaveRule{.{ .seconds = 300, .changes = 100 }};
    try testing.expect(!state.dueForSave(time.nowMs(testing.io), &rules));
}

test "dueForSave is false before enough changes even after the seconds threshold elapses" {
    const testing = std.testing;
    var state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });

    for (0..99) |_| state.recordChange();

    const rules = [_]Config.SaveRule{.{ .seconds = 300, .changes = 100 }};
    const now_ms = time.nowMs(testing.io) + 300 * 1000;
    try testing.expect(!state.dueForSave(now_ms, &rules));
}

test "dueForSave is true once both thresholds are met" {
    const testing = std.testing;
    var state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });

    for (0..100) |_| state.recordChange();

    const rules = [_]Config.SaveRule{.{ .seconds = 300, .changes = 100 }};
    const now_ms = time.nowMs(testing.io) + 300 * 1000;
    try testing.expect(state.dueForSave(now_ms, &rules));
}

test "dueForSave is true when any configured rule matches" {
    const testing = std.testing;
    var state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });

    for (0..5) |_| state.recordChange();

    const rules = [_]Config.SaveRule{
        .{ .seconds = 900, .changes = 10_000 },
        .{ .seconds = 300, .changes = 10_000 },
        .{ .seconds = 60, .changes = 1 },
    };
    const now_ms = time.nowMs(testing.io) + 60 * 1000;
    try testing.expect(state.dueForSave(now_ms, &rules));
}

test "markSaved resets the change count and last-save time" {
    const testing = std.testing;
    var state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });

    for (0..100) |_| state.recordChange();

    const rules = [_]Config.SaveRule{.{ .seconds = 300, .changes = 100 }};
    const now_ms = time.nowMs(testing.io) + 300 * 1000;
    try testing.expect(state.dueForSave(now_ms, &rules));

    {
        var tx = try state.begin();
        defer tx.end();
        try state.markSaved(state.captureSnapshotChangeCount(), now_ms);
    }

    try testing.expect(!state.dueForSave(now_ms, &rules));
}

test "markSaved preserves changes recorded after capture" {
    const testing = std.testing;
    var state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });

    for (0..3) |_| state.recordChange();
    const snapshot_change_count = state.captureSnapshotChangeCount();
    for (0..2) |_| state.recordChange();

    {
        var tx = try state.begin();
        defer tx.end();
        try state.markSaved(snapshot_change_count, time.nowMs(testing.io));
    }

    try testing.expectEqual(2, state.captureSnapshotChangeCount());
}

test "markSaved rejects a count greater than the current change count" {
    const testing = std.testing;
    var state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });
    state.recordChange();

    {
        var tx = try state.begin();
        defer tx.end();
        try testing.expectError(
            error.InvalidSavedChangeCount,
            state.markSaved(2, time.nowMs(testing.io)),
        );
    }

    try testing.expectEqual(1, state.captureSnapshotChangeCount());
}

test "concurrent recordChange calls are never lost" {
    const testing = std.testing;
    var state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });

    const thread_count = 8;
    const increments_per_thread = 10_000;

    const worker = struct {
        fn run(persistence_state: *PersistenceState) void {
            for (0..increments_per_thread) |_| persistence_state.recordChange();
        }
    }.run;

    var threads: [thread_count]std.Thread = undefined;
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, worker, .{&state});
    }
    for (threads) |thread| thread.join();

    try testing.expectEqual(
        @as(u64, thread_count * increments_per_thread),
        state.captureSnapshotChangeCount(),
    );
}
