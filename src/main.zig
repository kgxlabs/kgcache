const std = @import("std");
const resp = @import("resp.zig");
const commander = @import("commander.zig");
const store = @import("store.zig");
const helpers = @import("helpers.zig");
const storage = @import("storage.zig");
const time = @import("time.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    try std.Io.File.writeStreamingAll(std.Io.File.stderr(), io, "Logs from your program will appear here!\n");

    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 6379);

    var server = try address.listen(io, .{
        .reuse_address = true,
    });
    defer server.deinit(io);
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    var default_storage = storage.DefaultStorage.init(io, allocator);
    const data_storage = default_storage.storage();
    var mem_store = store.MemoryStore.init(data_storage);
    var data_store = mem_store.store();

    // Spin up active expiration
    const handle = try std.Thread.spawn(.{}, handleExpiration, .{ io, data_storage });
    handle.detach();

    // `MemoryStore` owns the storage interface, so `data_store.deinit()` also
    // deinitializes `default_storage`. Do not deinitialize it separately.
    defer data_store.deinit();

    try listen(io, &server, &data_store);
}

fn listen(io: std.Io, server: *std.Io.net.Server, data_store: *store.Store) !void {
    while (true) {
        const connection = try server.accept(io);
        const handle = try std.Thread.spawn(.{}, handleConnection, .{ io, connection, data_store });
        handle.detach();
    }
}

fn handleExpiration(io: std.Io, data_storage: storage.Interface) !void {
    const round_duration = std.Io.Duration.fromMilliseconds(100);
    const timeout_duration = std.Io.Duration.fromMilliseconds(100);
    const budget_ms: i8 = 10;
    const batch_size: i8 = 20;
    const threshold: i8 = 25;

    while (true) {
        try io.sleep(round_duration, .awake);

        if (data_storage.getExpirableCount() == 0) {
            continue;
        }

        // batch starts
        batch: while (true) {
            var expired_count: i8 = 0;
            const burst_start_ms = time.nowMs(io);

            for (0..batch_size) |_| {
                const is_removed = try expireRandom(data_storage);
                if (is_removed) {
                    expired_count += 1;
                }

                // throttle if it took more than budget
                if (time.nowMs(io) - burst_start_ms >= budget_ms) {
                    try io.sleep(timeout_duration, .awake);
                }
            }

            // When batch size is reached, >= 25% expired => immediately start next batch.
            const expired_percentage = @divTrunc(expired_count * 100, batch_size);
            if (expired_percentage >= threshold) {
                continue :batch;
            }

            break :batch;
        }
    }
}

// NOTE: We are releasing lock on when err and when the transaction succeeded so that we dont starve the main threads
fn expireRandom(data_storage: storage.Interface) !bool {
    var tx = try data_storage.begin();
    errdefer tx.end();

    const is_removed = try data_storage.tryExpireRandom();
    tx.end();

    return is_removed;
}

fn handleConnection(io: std.Io, connection: std.Io.net.Stream, data_store: *store.Store) !void {
    defer connection.close(io);

    while (true) {
        // TODO: use buffered writer
        var connection_writer = connection.writer(io, &.{});
        var buf: [1024]u8 = undefined;
        var data = [_][]u8{&buf};

        // TODO: We are directly doing syscall to OS which is expensive. Refactor this to use buffered reader
        const bytes_read = io.vtable.netRead(io.userdata, connection.socket.handle, &data) catch break;
        if (bytes_read == 0) break;

        var gpa: std.heap.DebugAllocator(.{}) = .init;
        defer _ = gpa.deinit();

        const allocator = gpa.allocator();
        const serializer = resp.serializer();

        var parser = resp.parser(buf[0..bytes_read]);
        // NOTE: There is a potential memory leak when error occurs.
        // This is the scenario: error can happens when parsing Array type and there are some array items already allocated.
        // We don't need to worry about that because we already errdefer it in parser implementation
        const commands = parser.parse(allocator) catch |err| {
            const err_value = resp.errorToRESPValue(err);

            const serialized_value = try serializer.serialize(allocator, err_value);
            defer allocator.free(serialized_value);

            try connection_writer.interface.writeAll(serialized_value);
            return;
        };
        defer parser.deinit(allocator, commands);

        const c = commander.init(allocator, commands) catch |err| {
            const err_value = commander.errorToRESPValue(err);

            const serialized_value = try serializer.serialize(allocator, err_value);
            defer allocator.free(serialized_value);

            try connection_writer.interface.writeAll(serialized_value);
            return;
        };
        defer c.deinit();

        // TODO: There is a potential memory leak when error occurs.
        // This is the scenario: error can happens when serializing a RESP value and there are some items already allocated.
        // How do we handle that scenario to free the memory?
        const result = c.execute(io, data_store) catch |err| {
            const err_value = commander.errorToRESPValue(err);

            const serialized_value = try serializer.serialize(allocator, err_value);
            defer allocator.free(serialized_value);

            try connection_writer.interface.writeAll(serialized_value);
            return;
        };

        const serialized_result = serializer.serialize(allocator, result) catch {
            try connection_writer.interface.writeAll("-ERR something went wrong\r\n");
            return;
        };

        defer serializer.deinit(allocator, serialized_result);

        // Write serialized string
        try connection_writer.interface.writeAll(serialized_result);
    }
}
