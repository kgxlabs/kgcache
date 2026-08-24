const std = @import("std");
const time = @import("time.zig");
const Config = @import("config.zig");

const ChangeTracker = @This();

/// Number of writes (put/remove) since the last save.
_dirty: std.atomic.Value(u64) = .init(0),
/// Timestamp of the last save, initialized to "now" at construction (not
/// 0) so a freshly-started server with no save rules matching yet doesn't
/// look like it's infinitely overdue.
_last_save_ms: std.atomic.Value(i64),

pub fn init(io: std.Io) ChangeTracker {
    return .{
        ._last_save_ms = .init(time.nowMs(io)),
    };
}

/// Called from NotifierStorage on every put/remove.
pub fn recordChange(self: *ChangeTracker) void {
    _ = self._dirty.fetchAdd(1, .monotonic);
}

/// Returns true if ANY rule's condition is met
/// rules are OR'd together,
pub fn dueForSave(self: *ChangeTracker, now_ms: i64, rules: []const Config.SaveRule) bool {
    const dirty = self._dirty.load(.monotonic);
    const last_save_ms = self._last_save_ms.load(.monotonic);
    const elapsed_seconds = @divFloor(now_ms - last_save_ms, 1000);

    for (rules) |rule| {
        if (elapsed_seconds >= rule.seconds and dirty >= rule.changes) return true;
    }
    return false;
}

/// Called once a save has actually finished writing to disk
pub fn markSaved(self: *ChangeTracker, now_ms: i64) void {
    // swap(0, ...) rather than "read, then separately write 0" -- one indivisible op,
    _ = self._dirty.swap(0, .monotonic);
    self._last_save_ms.store(now_ms, .monotonic);
}

test "dueForSave is false with no rules configured" {
    const testing = std.testing;
    var tracker = ChangeTracker.init(testing.io);

    tracker.recordChange();
    try testing.expect(!tracker.dueForSave(time.nowMs(testing.io), &.{}));
}

test "dueForSave is false before the seconds threshold elapses even with enough changes" {
    const testing = std.testing;
    var tracker = ChangeTracker.init(testing.io);

    for (0..100) |_| tracker.recordChange();

    const rules = [_]Config.SaveRule{.{ .seconds = 300, .changes = 100 }};
    const now_ms = time.nowMs(testing.io);
    try testing.expect(!tracker.dueForSave(now_ms, &rules));
}

test "dueForSave is false before enough changes even after the seconds threshold elapses" {
    const testing = std.testing;
    var tracker = ChangeTracker.init(testing.io);

    for (0..99) |_| tracker.recordChange();

    const rules = [_]Config.SaveRule{.{ .seconds = 300, .changes = 100 }};
    const now_ms = time.nowMs(testing.io) + 300 * 1000;
    try testing.expect(!tracker.dueForSave(now_ms, &rules));
}

test "dueForSave is true once both thresholds are met for at least one rule" {
    const testing = std.testing;
    var tracker = ChangeTracker.init(testing.io);

    for (0..100) |_| tracker.recordChange();

    const rules = [_]Config.SaveRule{.{ .seconds = 300, .changes = 100 }};
    const now_ms = time.nowMs(testing.io) + 300 * 1000;
    try testing.expect(tracker.dueForSave(now_ms, &rules));
}

test "dueForSave is true when ANY one of several rules matches, not just the first" {
    const testing = std.testing;
    var tracker = ChangeTracker.init(testing.io);

    for (0..5) |_| tracker.recordChange();

    const rules = [_]Config.SaveRule{
        .{ .seconds = 900, .changes = 1 },
        .{ .seconds = 300, .changes = 10000 },
        .{ .seconds = 60, .changes = 10000 },
    };
    const now_ms = time.nowMs(testing.io) + 900 * 1000;
    try testing.expect(tracker.dueForSave(now_ms, &rules));
}

test "markSaved resets the dirty count and updates the timestamp, so dueForSave goes back to false immediately after" {
    const testing = std.testing;
    var tracker = ChangeTracker.init(testing.io);

    for (0..100) |_| tracker.recordChange();

    const rules = [_]Config.SaveRule{.{ .seconds = 300, .changes = 100 }};
    const now_ms = time.nowMs(testing.io) + 300 * 1000;
    try testing.expect(tracker.dueForSave(now_ms, &rules));

    tracker.markSaved(now_ms);

    try testing.expect(!tracker.dueForSave(now_ms, &rules));
}

test "concurrent recordChange calls are never lost" {
    const testing = std.testing;
    var tracker = ChangeTracker.init(testing.io);

    const thread_count = 8;
    const increments_per_thread = 10_000;

    const worker = struct {
        fn run(t: *ChangeTracker) void {
            for (0..increments_per_thread) |_| t.recordChange();
        }
    }.run;

    var threads: [thread_count]std.Thread = undefined;
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, worker, .{&tracker});
    }
    for (threads) |thread| thread.join();
    const value = tracker._dirty.load(.monotonic);
    try testing.expectEqual(thread_count * increments_per_thread, value);
}
