const std = @import("std");
const storage = @import("storage.zig");
const time = @import("time.zig");
const Config = @import("config.zig");

// Visits every db once per round, starting from `start` (which rotates every
// round so a chronically-busy db can't perpetually starve the others), under
// a single time budget shared across the whole round rather than a budget per db.
// Once the round's budget is spent, the round bails out immediately
// wherever it is; whatever wasn't reached gets first priority next round via
// rotation. Returns the `start` to use for the next round.
pub fn runRound(io: std.Io, allocator: std.mem.Allocator, data_storages: []const storage.Interface, start: usize, config: Config) !usize {
    const budget_ms = config.active_expire_budget_ms;
    const batch_size = config.active_expire_batch_size;
    const threshold = config.active_expire_threshold_percent;

    const round_start_ms = time.nowMs(io);

    round: for (0..data_storages.len) |offset| {
        const db_storage = data_storages[(start + offset) % data_storages.len];

        if (db_storage.getExpirableCount() == 0) {
            continue :round;
        }

        // batch starts
        batch: while (true) {
            var expired_count: i8 = 0;

            for (0..@intCast(batch_size)) |_| {
                const is_removed = try expireRandom(allocator, db_storage);
                if (is_removed) {
                    expired_count += 1;
                }

                // bail the whole round if it took more than the shared budget
                if (time.nowMs(io) - round_start_ms >= budget_ms) {
                    break :round;
                }
            }

            // When batch size is reached, >= 25% expired => immediately start next batch on this db.
            const expired_percentage = @divTrunc(expired_count * 100, batch_size);
            if (expired_percentage >= threshold) {
                continue :batch;
            }

            break :batch;
        }
    }

    return (start + 1) % data_storages.len;
}

// NOTE: We are releasing lock on when err and when the transaction succeeded so that we dont starve the main threads
fn expireRandom(allocator: std.mem.Allocator, data_storage: storage.Interface) !bool {
    var tx = try data_storage.begin();
    errdefer tx.end();

    const removed_key = try data_storage.tryExpireRandom();
    tx.end();

    if (removed_key) |key| {
        allocator.free(key);
        return true;
    }

    return false;
}

test "runRound visits every db in a round, not just the first" {
    const testing = std.testing;

    var backend_zero = storage.DefaultStorage.init(testing.io, testing.allocator);
    defer backend_zero.storage().deinit();
    var backend_one = storage.DefaultStorage.init(testing.io, testing.allocator);
    defer backend_one.storage().deinit();

    const data_storages = [_]storage.Interface{ backend_zero.storage(), backend_one.storage() };

    _ = try data_storages[0].put("expiring-zero", .{ .string = "value" }, .{
        .expires_at = time.nowMs(testing.io) - 1,
    });
    _ = try data_storages[1].put("expiring-one", .{ .string = "value" }, .{
        .expires_at = time.nowMs(testing.io) - 1,
    });

    const next_start = try runRound(testing.io, testing.allocator, &data_storages, 0, Config.default());

    try testing.expectEqual(0, data_storages[0].getExpirableCount());
    try testing.expectEqual(0, data_storages[1].getExpirableCount());
    try testing.expectEqual(1, next_start);
}
