const std = @import("std");
const Lock = @import("../lock.zig");

const CapacityCalculator = @This();

pub const Config = struct {
    // Max cap of worker occupancy
    utilization_target: f64,
    occupancy_tau_ns: std.Io.Duration,
    // Max cap of the wait/delay time of work that are ready
    ready_target_ns: std.Io.Duration,
    ready_peak_tau_ns: std.Io.Duration,
    ready_close_limit_ns: std.Io.Duration,
    ready_reopen_limit_ns: std.Io.Duration,
    setup_wait_limit_ns: std.Io.Duration,
    uninterrupted_work_limit_ns: std.Io.Duration,
    setup_horizon_ns: std.Io.Duration,
    initial_setup_cost_ns: std.Io.Duration,
    setup_sample_weight: f64,
    min_closed_time_ns: std.Io.Duration,
    recovery_window_ns: std.Io.Duration,

    pub fn validate(self: Config) error{InvalidCapacityConfig}!void {
        _ = self;
        @panic("CapacityCalculator.Config.validate is not implemented");
    }
};

// Shared refusal errors for assessment, enqueue, and worker registration.
pub const AdmissionError = error{
    WorkerNotAccepting,
    IncomingQueueFull,
    WorkerConnectionLimit,
    UnfinishedSetupLimit,
    WorkerBufferLimit,
    ReadyDelayLimit,
    AdmissionRecovering,
    SetupWaitLimit,
    UninterruptedWorkLimit,
};

// An allowed score is finite and nonnegative. Zero is a valid score.
pub const Assessment = union(enum) {
    allowed: f64,
    refused: AdmissionError,
};

// Copied under the admission lock. Evaluation does not reserve these resources.
pub const AdmissionView = struct {
    accepting: bool,
    queued: usize,
    oldest_enqueued_at_ns: ?std.Io.Timestamp,
    initializing: usize,
    owned: usize,
    reserved_buffer_bytes: usize,
    queue_limit: usize,
    connection_limit: usize,
    unfinished_setup_limit: usize,
    buffer_limit_bytes: usize,
    initial_buffer_bytes: usize,
};

pub const Phase = enum { processing, waiting };

const Occupancy = struct {
    base: f64,
    since_ns: std.Io.Timestamp,
    phase: Phase,
};

const ReadyPeak = struct {
    value_ns: f64,
    at_ns: std.Io.Timestamp,
};

const Recovery = struct {
    closed: bool = false,
    min_closed_until_ns: ?std.Io.Timestamp = null,
    healthy_since_ns: ?std.Io.Timestamp = null,
};

const State = struct {
    occupancy: Occupancy,
    last_scheduler_boundary_ns: std.Io.Timestamp,
    oldest_ready_since_ns: ?std.Io.Timestamp = null,
    recent_wait_peak: ReadyPeak,
    average_setup_ns: f64,
    recovery: Recovery = .{},
};

_config: Config,
_lock: Lock,
_state: State,

pub fn init(io: std.Io, config: Config, now_ns: std.Io.Timestamp) !CapacityCalculator {
    try config.validate();
    return .{
        ._config = config,
        ._lock = Lock.init(io),
        ._state = .{
            .occupancy = .{ .base = 0, .since_ns = now_ns, .phase = .processing },
            .last_scheduler_boundary_ns = now_ns,
            .recent_wait_peak = .{ .value_ns = 0, .at_ns = now_ns },
            .average_setup_ns = @floatFromInt(config.initial_setup_cost_ns.toNanoseconds()),
        },
    };
}

// Read-only projection. Never update averages or recovery from this call.
pub fn evaluate(self: *CapacityCalculator, view: AdmissionView, now_ns: std.Io.Timestamp) Assessment {
    if (checkHardLimits(view)) |reason| return .{ .refused = reason };
    var tx = self._lock.beginUncancelable();
    defer tx.end();
    return self.evaluateLocked(view, now_ns);
}

fn evaluateLocked(self: *CapacityCalculator, view: AdmissionView, now_ns: std.Io.Timestamp) Assessment {
    // A worker can publish after now_ns was captured. Clamp projected ages to zero.
    _ = .{ self, view, now_ns };
    @panic("CapacityCalculator.evaluateLocked is not implemented");
}

// Shared pure checks for assessment and the final admission transaction.
pub fn checkHardLimits(view: AdmissionView) ?AdmissionError {
    _ = view;
    @panic("CapacityCalculator.checkHardLimits is not implemented");
}

// Worker-only updates. Hold the state lock only while publishing measurements.
pub fn setPhase(self: *CapacityCalculator, phase: Phase, now_ns: std.Io.Timestamp) void {
    _ = .{ self, phase, now_ns };
    @panic("CapacityCalculator.setPhase is not implemented");
}

pub fn recordSchedulerCheckpoint(self: *CapacityCalculator, now_ns: std.Io.Timestamp) void {
    var tx = self._lock.beginUncancelable();
    defer tx.end();
    self._state.last_scheduler_boundary_ns = now_ns;
}

// Publish the replacement head and served wait together under one lock.
pub fn readyChanged(self: *CapacityCalculator, oldest_ready_since_ns: ?std.Io.Timestamp, served_wait_ns: ?std.Io.Duration, now_ns: std.Io.Timestamp) void {
    _ = .{ self, oldest_ready_since_ns, served_wait_ns, now_ns };
    @panic("CapacityCalculator.readyChanged is not implemented");
}

pub fn setupFinished(self: *CapacityCalculator, elapsed_ns: std.Io.Duration, now_ns: std.Io.Timestamp) void {
    _ = .{ self, elapsed_ns, now_ns };
    @panic("CapacityCalculator.setupFinished is not implemented");
}

pub fn updateRecovery(self: *CapacityCalculator, now_ns: std.Io.Timestamp) void {
    var tx = self._lock.beginUncancelable();
    defer tx.end();

    // Recent waits still count, even if no ready work is waiting now.
    const ready_delay_ns = self.readyDelay(now_ns);
    const recovery = &self._state.recovery;

    // Admission is open. If ready delay reaches the close limit,
    // close admission and start the minimum closed timer.
    if (!recovery.closed) {
        const close_limit_ns: f64 = @floatFromInt(self._config.ready_close_limit_ns.toNanoseconds());
        if (ready_delay_ns >= close_limit_ns) {
            recovery.* = .{
                .closed = true,
                .min_closed_until_ns = now_ns.addDuration(self._config.min_closed_time_ns),
            };
        }
        return;
    }

    const reopen_limit_ns: f64 = @floatFromInt(self._config.ready_reopen_limit_ns.toNanoseconds());
    if (ready_delay_ns >= reopen_limit_ns) {
        // Admission is already closed, and the worker is not healthy yet.
        // Clear the healthy window so it can start again when delay improves.
        recovery.healthy_since_ns = null;
        return;
    }

    // Ready delay is below the reopen limit, so the worker is healthy now.
    // It must stay healthy for the recovery window and wait for the minimum closed time to pass.
    if (recovery.healthy_since_ns == null) recovery.healthy_since_ns = now_ns;

    const healthy_for_ns = recovery.healthy_since_ns.?.durationTo(now_ns).toNanoseconds();
    const min_closed_time_passed = now_ns.toNanoseconds() >= recovery.min_closed_until_ns.?.toNanoseconds();
    const healthy_window_passed = healthy_for_ns >= self._config.recovery_window_ns.toNanoseconds();

    // Both timers must pass before the worker can accept new connections.
    if (min_closed_time_passed and healthy_window_passed) {
        recovery.* = .{};
    }
}

// Project delay without changing the published ready head or recent peak.
fn readyDelay(self: *const CapacityCalculator, now_ns: std.Io.Timestamp) f64 {
    const oldest_wait_ns: f64 = if (self._state.oldest_ready_since_ns) |since_ns|
        @floatFromInt(@max(0, since_ns.durationTo(now_ns).toNanoseconds()))
    else
        0;
    const peak = self._state.recent_wait_peak;
    const peak_age_ns: f64 = @floatFromInt(@max(0, peak.at_ns.durationTo(now_ns).toNanoseconds()));
    const peak_tau_ns: f64 = @floatFromInt(self._config.ready_peak_tau_ns.toNanoseconds());
    const recent_wait_ns = peak.value_ns * @exp(-peak_age_ns / peak_tau_ns);
    return @max(oldest_wait_ns, recent_wait_ns);
}

pub fn nextUpdateAt(self: *CapacityCalculator, now_ns: std.Io.Timestamp) ?std.Io.Timestamp {
    _ = .{ self, now_ns };
    @panic("CapacityCalculator.nextUpdateAt is not implemented");
}
