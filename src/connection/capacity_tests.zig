const std = @import("std");
const testing = std.testing;
const Lock = @import("../lock.zig");
const CapacityCalculator = @import("capacity.zig");

test "capacity scheduler boundary publishes progress without changing recovery or occupancy" {
    var capacity = fixture();
    capacity._state.recovery = .{
        .closed = true,
        .min_closed_until_ns = at(200),
        .healthy_since_ns = at(130),
    };
    const occupancy = capacity._state.occupancy;

    capacity.schedulerBoundary(at(150));
    try testing.expectEqual(at(150), capacity._state.last_scheduler_boundary_ns);
    try testing.expectEqualDeep(occupancy, capacity._state.occupancy);
    try expectRecovery(&capacity, true, 200, 130);

    capacity.schedulerBoundary(at(160));
    try testing.expectEqual(at(160), capacity._state.last_scheduler_boundary_ns);
}

test "capacity recovery closes at the limit and does not extend the minimum closed time" {
    var capacity = fixture();
    capacity.updateRecovery(at(90));
    try expectRecovery(&capacity, false, null, null);

    capacity._state.oldest_ready_since_ns = at(80);
    capacity.updateRecovery(at(99));
    try expectRecovery(&capacity, false, null, null);

    capacity.updateRecovery(at(100));
    try expectRecovery(&capacity, true, 200, null);

    capacity.updateRecovery(at(150));
    try expectRecovery(&capacity, true, 200, null);
    capacity.updateRecovery(at(250));
    try expectRecovery(&capacity, true, 200, null);
}

test "capacity recovery waits for the minimum closed time after the healthy window passes" {
    var capacity = fixture();
    capacity._state.oldest_ready_since_ns = at(80);
    capacity.updateRecovery(at(100));
    try expectRecovery(&capacity, true, 200, null);

    capacity._state.oldest_ready_since_ns = null;
    capacity.updateRecovery(at(130));
    try expectRecovery(&capacity, true, 200, 130);
    capacity.updateRecovery(at(180));
    try expectRecovery(&capacity, true, 200, 130);
    capacity.updateRecovery(at(199));
    try expectRecovery(&capacity, true, 200, 130);
    capacity.updateRecovery(at(200));
    try expectRecovery(&capacity, false, null, null);

    // Another overload starts a new closure with a fresh deadline.
    capacity._state.oldest_ready_since_ns = at(200);
    capacity.updateRecovery(at(220));
    try expectRecovery(&capacity, true, 320, null);
}

test "capacity recovery restarts the healthy window at or above the reopen limit" {
    for ([_]i64{ 10, 12, 25 }) |delay_ms| {
        var capacity = fixture();
        capacity._state.oldest_ready_since_ns = at(80);
        capacity.updateRecovery(at(100));

        capacity._state.oldest_ready_since_ns = null;
        capacity.updateRecovery(at(130));
        try expectRecovery(&capacity, true, 200, 130);

        capacity._state.oldest_ready_since_ns = at(160 - delay_ms);
        capacity.updateRecovery(at(160));
        try expectRecovery(&capacity, true, 200, null);

        capacity._state.oldest_ready_since_ns = null;
        capacity.updateRecovery(at(190));
        try expectRecovery(&capacity, true, 200, 190);
        capacity.updateRecovery(at(200));
        try expectRecovery(&capacity, true, 200, 190);
        capacity.updateRecovery(at(239));
        try expectRecovery(&capacity, true, 200, 190);
        capacity.updateRecovery(at(240));
        try expectRecovery(&capacity, false, null, null);
    }
}

test "capacity recovery uses the decaying recent wait peak even with no ready head" {
    var capacity = fixture();
    capacity._state.recent_wait_peak = .{ .value_ns = 40 * std.time.ns_per_ms, .at_ns = at(100) };
    const peak = capacity._state.recent_wait_peak;
    capacity.updateRecovery(at(100));
    try expectRecovery(&capacity, true, 200, null);

    // After one time constant, the peak is about 14.7 ms, above the reopen limit.
    capacity.updateRecovery(at(200));
    try expectRecovery(&capacity, true, 200, null);
    // At 240 ms the peak is about 9.9 ms, so recovery can start.
    capacity.updateRecovery(at(240));
    try expectRecovery(&capacity, true, 200, 240);
    capacity.updateRecovery(at(289));
    try expectRecovery(&capacity, true, 200, 240);
    capacity.updateRecovery(at(290));
    try expectRecovery(&capacity, false, null, null);
    try testing.expectEqualDeep(peak, capacity._state.recent_wait_peak);
}

test "capacity recovery clamps future measurement ages to zero" {
    var capacity = fixture();
    capacity._state.oldest_ready_since_ns = at(200);
    capacity._state.recent_wait_peak = .{ .value_ns = 9 * std.time.ns_per_ms, .at_ns = at(200) };
    capacity.updateRecovery(at(100));
    try expectRecovery(&capacity, false, null, null);

    capacity._state.recent_wait_peak.value_ns = 20 * std.time.ns_per_ms;
    capacity.updateRecovery(at(100));
    try expectRecovery(&capacity, true, 200, null);
}

fn at(milliseconds: i64) std.Io.Timestamp {
    return .fromNanoseconds(std.Io.Duration.fromMilliseconds(milliseconds).toNanoseconds());
}

fn expectRecovery(capacity: *CapacityCalculator, closed: bool, min_closed_until_ms: ?i64, healthy_since_ms: ?i64) !void {
    var tx = capacity._lock.tryBegin() orelse return error.CapacityLockStillHeld;
    defer tx.end();
    const recovery = capacity._state.recovery;
    try testing.expectEqual(closed, recovery.closed);
    const min_closed_until: ?std.Io.Timestamp = if (min_closed_until_ms) |ms| at(ms) else null;
    const healthy_since: ?std.Io.Timestamp = if (healthy_since_ms) |ms| at(ms) else null;
    try testing.expectEqual(min_closed_until, recovery.min_closed_until_ns);
    try testing.expectEqual(healthy_since, recovery.healthy_since_ns);
}

fn fixture() CapacityCalculator {
    return .{
        ._config = .{
            .utilization_target = 0.8,
            .occupancy_tau_ns = .fromMilliseconds(100),
            .ready_target_ns = .fromMilliseconds(5),
            .ready_peak_tau_ns = .fromMilliseconds(100),
            .ready_close_limit_ns = .fromMilliseconds(20),
            .ready_reopen_limit_ns = .fromMilliseconds(10),
            .setup_wait_limit_ns = .fromMilliseconds(100),
            .uninterrupted_work_limit_ns = .fromMilliseconds(20),
            .setup_horizon_ns = .fromMilliseconds(100),
            .initial_setup_cost_ns = .fromMilliseconds(1),
            .setup_sample_weight = 0.1,
            .min_closed_time_ns = .fromMilliseconds(100),
            .recovery_window_ns = .fromMilliseconds(50),
        },
        ._lock = Lock.init(testing.io),
        ._state = .{
            .occupancy = .{ .base = 0, .since_ns = .zero, .phase = .processing },
            .last_scheduler_boundary_ns = .zero,
            .recent_wait_peak = .{ .value_ns = 0, .at_ns = .zero },
            .average_setup_ns = std.time.ns_per_ms,
        },
    };
}
