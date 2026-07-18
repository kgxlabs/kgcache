const std = @import("std");
const resp = @import("resp.zig");
const commander = @import("commander.zig");
const store = @import("store.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    // You can use print statements as follows for debugging, they'll be visible when running tests.
    try std.Io.File.writeStreamingAll(std.Io.File.stderr(), io, "Logs from your program will appear here!\n");

    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 6379);

    var server = try address.listen(io, .{
        .reuse_address = true,
    });
    defer server.deinit(io);
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    var mem_store = store.MemoryStore.init(allocator);
    var data_store = mem_store.store();

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

        const c = commander.init(commands) catch |err| {
            const err_value = commander.errorToRESPValue(err);

            const serialized_value = try serializer.serialize(allocator, err_value);
            defer allocator.free(serialized_value);

            try connection_writer.interface.writeAll(serialized_value);
            return;
        };

        // TODO: There is a potential memory leak when error occurs.
        // This is the scenario: error can happens when serializing a RESP value and there are some items already allocated.
        // How do we handle that scenario to free the memory?
        const result = c.execute(data_store) catch |err| {
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
