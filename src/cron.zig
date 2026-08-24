const std = @import("std");
const storage = @import("storage.zig");
const PersistenceState = @import("persistence_state.zig");
const ChangeTracker = @import("change_tracker.zig");
const Config = @import("config.zig");
const expiration = @import("expiration.zig");

pub fn run(
    io: std.Io,
    allocator: std.mem.Allocator,
    data_storages: []const storage.Interface,
    persistence_state: *PersistenceState,
    _: *ChangeTracker,
    config: Config,
) !void {
    const round_duration = std.Io.Duration.fromMilliseconds(config.cron_interval_ms);
    var start: usize = 0;

    while (true) {
        try io.sleep(round_duration, .awake);
        start = try expiration.runRound(io, allocator, data_storages, start, config);

        // clean up forked child processes if any
        persistence_state.reapKgc();
        persistence_state.reapAof();
    }
}
