const std = @import("std");
const resp = @import("resp.zig");
const commander = @import("commander.zig");
const ClientState = @import("client_state.zig");
const store = @import("store.zig");
const Config = @import("config.zig");

pub fn acceptLoop(io: std.Io, server: *std.Io.net.Server, data_store: *store.Store, con_allocator: std.mem.Allocator, config: Config) !void {
    while (true) {
        const connection = try server.accept(io);
        const handle_thread = try std.Thread.spawn(.{}, handle, .{ io, connection, data_store, con_allocator, config.connection_buffer_size });
        handle_thread.detach();
    }
}

pub fn handle(io: std.Io, connection: std.Io.net.Stream, data_store: *store.Store, con_allocator: std.mem.Allocator, connection_buffer_size: usize) !void {
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
            try writeError(req_allocator, &connection_writer.interface, serializer, resp.errorToRESPValue(err));
            return;
        };
        defer parser.deinit(req_allocator, commands);

        const c = commander.init(req_allocator, commands) catch |err| {
            try writeError(req_allocator, &connection_writer.interface, serializer, commander.errorToRESPValue(err));
            return;
        };
        defer c.deinit();

        // TODO: There is a potential memory leak when error occurs.
        // This is the scenario: error can happens when serializing a RESP value and there are some items already allocated.
        // How do we handle that scenario to free the memory?
        const result = c.execute(io, data_store, &client_state) catch |err| {
            try writeError(req_allocator, &connection_writer.interface, serializer, commander.errorToRESPValue(err));
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

fn writeError(allocator: std.mem.Allocator, writer: *std.Io.Writer, serializer: resp.Serializer, err_value: resp.RESPValue) !void {
    const serialized_value = try serializer.serialize(allocator, err_value);
    defer serializer.deinit(allocator, serialized_value);

    try writer.writeAll(serialized_value);
}
