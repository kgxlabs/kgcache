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
};

const ShutdownState = enum {
    ready,
    child_tracked,
    aof_unresolved,
};

/// Call after cron and all client workers have joined.
pub fn run(
    io: std.Io,
    logger: logging.Logger,
    state: *PersistenceState,
    maybe_aof: ?JournalPersistence,
) Result {
    var drain_error: ?anyerror = null;

    while (true) {
        drainOnce(io, logger, state, maybe_aof, &drain_error);

        switch (getShutdownState(state, maybe_aof)) {
            .ready => return .{ .status = .complete, .err = drain_error },
            .child_tracked => {
                // An unexpected wait error leaves a PID tracked. Keep the
                // persistence resources alive and try the wait again.
                io.sleep(.fromMilliseconds(100), .awake) catch {};
            },
            .aof_unresolved => return .{
                .status = .aof_unresolved,
                .err = drain_error orelse error.AofRewriteUnsettled,
            },
        }
    }
}

fn drainOnce(
    io: std.Io,
    logger: logging.Logger,
    state: *PersistenceState,
    maybe_aof: ?JournalPersistence,
    drain_error: *?anyerror,
) void {
    var state_tx = state.beginUncancelable();
    const kgc_state = state.kgcShutdownState();
    const aof_state = state.aofShutdownState();
    state_tx.end();

    var log_buffer: [128]u8 = undefined;

    switch (kgc_state) {
        .no_child => {},
        .child => |save| {
            const message = std.fmt.bufPrint(
                &log_buffer,
                "server: waiting for BGSAVE child pid {d} during shutdown",
                .{save.pid},
            ) catch unreachable;
            logger.info(message);

            if (state.waitForKgcShutdown(time.nowMs(io))) |result| {
                finishKgc(io, logger, state, result, drain_error);
            } else |err| {
                recordError(logger, drain_error, "server: failed to wait for BGSAVE child", err);
            }
        },
    }

    switch (aof_state) {
        .no_child => {},
        .completed => |result| finishAof(logger, state, maybe_aof, result, drain_error),
        .child => |rewrite| {
            const message = std.fmt.bufPrint(
                &log_buffer,
                "server: waiting for BGREWRITEAOF child pid {d} during shutdown",
                .{rewrite.pid},
            ) catch unreachable;
            logger.info(message);

            if (state.waitForAofShutdown()) |result| {
                finishAof(logger, state, maybe_aof, result, drain_error);
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
        recordError(logger, drain_error, "server: BGSAVE child failed", err);
    } else if (result.status == .failed) {
        recordError(logger, drain_error, "server: BGSAVE child failed", error.BackgroundSaveFailed);
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
    if (result.report_error) |err| {
        recordError(logger, drain_error, "server: BGREWRITEAOF child failed", err);
    } else if (result.status == .failed) {
        recordError(logger, drain_error, "server: BGREWRITEAOF child failed", error.AofRewriteFailed);
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
