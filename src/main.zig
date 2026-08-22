const std = @import("std");
const resp = @import("resp.zig");
const commander = @import("commander.zig");
const ClientState = @import("client_state.zig");
const PersistenceState = @import("persistence_state.zig");
const store = @import("store.zig");
const helpers = @import("helpers.zig");
const storage = @import("storage.zig");
const persistence = @import("persistence.zig");
const time = @import("time.zig");
const Config = @import("config.zig");
const ConfigParser = @import("config_parser.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    try std.Io.File.writeStreamingAll(std.Io.File.stderr(), io, "Logs from your program will appear here!\n");

    const config = try loadConfig(init);

    const address = try std.Io.net.IpAddress.parseIp4(config.bind_address, config.port);

    var server = try address.listen(io, .{
        .reuse_address = config.reuse_address,
    });
    defer server.deinit(io);
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    const num_databases: usize = config.num_databases;

    // These slices must stay right here, in `main`'s stack frame (which
    // lives for the whole process) and never be resized or freed while in
    // use: `.storage()`/`.init()` below capture self-pointers (`.ptr`, and
    // `DefaultStorage`'s `._mutex`) into the elements they point at, so
    // reallocating or moving the backing memory after construction would
    // silently invalidate those pointers.
    const default_storages = try allocator.alloc(storage.DefaultStorage, num_databases);
    defer allocator.free(default_storages);
    for (default_storages) |*s| s.* = storage.DefaultStorage.init(io, allocator);

    var persistence_state = PersistenceState.init(io, config.exclusive_bg_persistence);

    var kgc_backend = try persistence.KgcPersistence.init(io, allocator, persistence_state, config.snapshot_path);
    var aof_backend = persistence.AofPersistence.init(allocator, persistence_state);

    // See `persistence.Persistence` for why `kgc`/`aof` are consumed by two
    // different layers below instead of both being handed to the same one.
    const backend_persistence = persistence.Persistence{
        .kgc = kgc_backend.snapshot(),
        .aof = aof_backend.journal(),
    };

    // Load against the raw storages, before they're wrapped for AOF
    // notification below
    // replaying an existing snapshot is not itself a write worth journaling,
    // and going through the notifying wrapper here would re-append every loaded key to the AOF log.
    const raw_storages = try allocator.alloc(storage.Interface, num_databases);
    defer allocator.free(raw_storages);
    for (0..num_databases) |i| raw_storages[i] = default_storages[i].storage();
    try backend_persistence.kgc.load(raw_storages);

    const notifier_storages = try allocator.alloc(storage.NotifierStorage, num_databases);
    defer allocator.free(notifier_storages);
    const data_storages = try allocator.alloc(storage.Interface, num_databases);
    defer allocator.free(data_storages);
    for (0..num_databases) |i| {
        notifier_storages[i] = storage.NotifierStorage.init(
            allocator,
            default_storages[i].storage(),
            backend_persistence.aof,
            @intCast(i),
        );
        data_storages[i] = notifier_storages[i].storage();
    }

    var mem_store = store.MemoryStore.init(data_storages, backend_persistence.kgc);
    var data_store = mem_store.store();

    // Spin up active expiration
    const handle = try std.Thread.spawn(.{}, handleServerCron, .{ io, allocator, data_storages, &persistence_state, config });
    handle.detach();

    // `MemoryStore` owns the storage interfaces, so `data_store.deinit()` also
    // deinitializes every `DefaultStorage`. Do not deinitialize them separately.
    defer data_store.deinit();

    try listen(io, &server, &data_store, allocator, config);
}

/// Reads the config file path from the first positional CLI argument, if
/// any (`kgcache [path/to/kgcache.conf]`); with no argument, returns
/// `Config.default()`. A path that can't be read
/// or doesn't parse fails the process fast, with a message on stderr,
/// rather than silently falling back to defaults.
fn loadConfig(init: std.process.Init) !Config {
    // NOTE: Using arena allocator instead of gap
    // We are not copying the parsed bytes. Instead, we are pointing to the raw file bytes we read
    // And we need those as long as the server lives , meaning we do not need to free them one by one
    // with gap, this will be flagged as a memory leak bug.
    // with arena allocator, we can free when server dies.
    const allocator = init.arena.allocator();

    var args = init.minimal.args.iterate();
    _ = args.skip(); // program name

    const conf_path = args.next() orelse return Config.default();

    const contents = std.Io.Dir.cwd().readFileAlloc(init.io, conf_path, allocator, .unlimited) catch |err| {
        try reportConfigError(init.io, allocator, "failed to read config file '{s}': {s}", .{ conf_path, @errorName(err) });
        return err;
    };

    return ConfigParser.parse(contents) catch |err| {
        try reportConfigError(init.io, allocator, "invalid config file '{s}': {s}", .{ conf_path, @errorName(err) });
        return err;
    };
}

fn reportConfigError(io: std.Io, allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const message = try std.fmt.allocPrint(allocator, "kgcache: " ++ fmt ++ "\n", args);
    try std.Io.File.writeStreamingAll(std.Io.File.stderr(), io, message);
}

fn listen(io: std.Io, server: *std.Io.net.Server, data_store: *store.Store, con_allocator: std.mem.Allocator, config: Config) !void {
    while (true) {
        const connection = try server.accept(io);
        const handle = try std.Thread.spawn(.{}, handleConnection, .{ io, connection, data_store, con_allocator, config.connection_buffer_size });
        handle.detach();
    }
}

fn handleServerCron(io: std.Io, allocator: std.mem.Allocator, data_storages: []const storage.Interface, persistence_state: *PersistenceState, config: Config) !void {
    const round_duration = std.Io.Duration.fromMilliseconds(config.cron_interval_ms);
    var start: usize = 0;

    while (true) {
        try io.sleep(round_duration, .awake);
        start = try runExpirationRound(io, allocator, data_storages, start, config);

        // clean up forked child processes if any
        persistence_state.reapKgc();
        persistence_state.reapAof();
    }
}

// Visits every db once per round, starting from `start` (which rotates every
// round so a chronically-busy db can't perpetually starve the others), under
// a single time budget shared across the whole round rather than a budget
// per db. Once the round's budget is spent, the round bails out immediately
// wherever it is; whatever wasn't reached gets first priority next round via
// rotation. Returns the `start` to use for the next round.
fn runExpirationRound(io: std.Io, allocator: std.mem.Allocator, data_storages: []const storage.Interface, start: usize, config: Config) !usize {
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

fn handleConnection(io: std.Io, connection: std.Io.net.Stream, data_store: *store.Store, con_allocator: std.mem.Allocator, connection_buffer_size: usize) !void {
    defer connection.close(io);

    var client_state = ClientState.init();

    const buf = try con_allocator.alloc(u8, connection_buffer_size);
    defer con_allocator.free(buf);

    while (true) {
        // TODO: use buffered writer
        var connection_writer = connection.writer(io, &.{});
        var data = [_][]u8{buf};

        // TODO: We are directly doing syscall to OS which is expensive. Refactor this to use buffered reader
        const bytes_read = io.vtable.netRead(io.userdata, connection.socket.handle, &data) catch break;
        if (bytes_read == 0) break;

        var gpa: std.heap.DebugAllocator(.{}) = .init;
        defer _ = gpa.deinit();

        const req_allocator = gpa.allocator();
        const serializer = resp.serializer();

        var parser = resp.parser(buf[0..bytes_read]);
        // NOTE: There is a potential memory leak when error occurs.
        // This is the scenario: error can happens when parsing Array type and there are some array items already allocated.
        // We don't need to worry about that because we already errdefer it in parser implementation
        const commands = parser.parse(req_allocator) catch |err| {
            const err_value = resp.errorToRESPValue(err);

            const serialized_value = try serializer.serialize(req_allocator, err_value);
            defer req_allocator.free(serialized_value);

            try connection_writer.interface.writeAll(serialized_value);
            return;
        };
        defer parser.deinit(req_allocator, commands);

        const c = commander.init(req_allocator, commands) catch |err| {
            const err_value = commander.errorToRESPValue(err);

            const serialized_value = try serializer.serialize(req_allocator, err_value);
            defer req_allocator.free(serialized_value);

            try connection_writer.interface.writeAll(serialized_value);
            return;
        };
        defer c.deinit();

        // TODO: There is a potential memory leak when error occurs.
        // This is the scenario: error can happens when serializing a RESP value and there are some items already allocated.
        // How do we handle that scenario to free the memory?
        const result = c.execute(io, data_store, &client_state) catch |err| {
            const err_value = commander.errorToRESPValue(err);

            const serialized_value = try serializer.serialize(req_allocator, err_value);
            defer req_allocator.free(serialized_value);

            try connection_writer.interface.writeAll(serialized_value);
            return;
        };

        const serialized_result = serializer.serialize(req_allocator, result) catch {
            try connection_writer.interface.writeAll("-ERR something went wrong\r\n");
            return;
        };

        defer serializer.deinit(req_allocator, serialized_result);

        // Write serialized string
        try connection_writer.interface.writeAll(serialized_result);
    }
}

test "runExpirationRound visits every db in a round, not just the first" {
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

    const next_start = try runExpirationRound(testing.io, testing.allocator, &data_storages, 0, Config.default());

    try testing.expectEqual(0, data_storages[0].getExpirableCount());
    try testing.expectEqual(0, data_storages[1].getExpirableCount());
    try testing.expectEqual(1, next_start);
}
