const std = @import("std");
const resp = @import("resp.zig");
const commander = @import("commander.zig");
const ClientState = @import("client_state.zig");
const store = @import("store.zig");
const Config = @import("config.zig");
const logging = @import("logger.zig");

pub fn acceptLoop(
    io: std.Io,
    logger: logging.Logger,
    server: *std.Io.net.Server,
    data_store: *store.Store,
    con_allocator: std.mem.Allocator,
    config: Config,
) !void {
    while (true) {
        const connection = try server.accept(io);
        const handle_thread = std.Thread.spawn(.{}, handle, .{
            io,
            logger,
            connection,
            data_store,
            con_allocator,
            config.connection_buffer_size,
        }) catch |err| {
            connection.close(io);
            return err;
        };
        handle_thread.detach();
    }
}

pub fn handle(
    io: std.Io,
    logger: logging.Logger,
    connection: std.Io.net.Stream,
    data_store: *store.Store,
    con_allocator: std.mem.Allocator,
    connection_buffer_size: usize,
) void {
    defer connection.close(io);

    const buf = con_allocator.alloc(u8, connection_buffer_size) catch |err| {
        logger.err(err, @errorReturnTrace());
        return;
    };
    defer con_allocator.free(buf);

    handleConnection(io, logger, connection, data_store, buf) catch |err| {
        logger.err(err, @errorReturnTrace());
    };
}

fn handleConnection(
    io: std.Io,
    logger: logging.Logger,
    connection: std.Io.net.Stream,
    data_store: *store.Store,
    buf: []u8,
) !void {
    var client_state = ClientState.init();

    while (true) {
        // TODO: use buffered writer
        var connection_writer = connection.writer(io, &.{});
        var data = [_][]u8{buf};

        // TODO: We are directly doing syscall to OS which is expensive. Refactor this to use buffered reader
        const bytes_read = io.vtable.netRead(io.userdata, connection.socket.handle, &data) catch |err| switch (err) {
            error.ConnectionResetByPeer => return,
            else => return err,
        };

        if (bytes_read == 0) return;

        var gpa: std.heap.DebugAllocator(.{}) = .init;
        defer _ = gpa.deinit();

        const req_allocator = gpa.allocator();
        const serializer = resp.serializer();

        var parser = resp.parser(buf[0..bytes_read]);
        // NOTE: There is a potential memory leak when error occurs.
        // This is the scenario: error can happens when parsing Array type and there are some array items already allocated.
        // We don't need to worry about that because we already errdefer it in parser implementation
        const commands = parser.parse(req_allocator) catch |err| {
            try connection_writer.interface.writeAll(resp.parseErrorResponse(err));
            return;
        };
        defer parser.deinit(req_allocator, commands);

        const c = commander.init(req_allocator, commands) catch |err| {
            const response = commander.initErrorResponse(err) orelse return err;
            try connection_writer.interface.writeAll(response);
            continue;
        };
        defer c.deinit();

        // TODO: There is a potential memory leak when error occurs.
        // This is the scenario: error can happens when serializing a RESP value and there are some items already allocated.
        // How do we handle that scenario to free the memory?

        // TODO: Some commands still return internal failures as successful RESP error values.
        // make those failures reach this catch for reporting.
        const result = c.execute(io, data_store, &client_state) catch |err| {
            if (commander.executeErrorResponse(err)) |response| {
                try connection_writer.interface.writeAll(response);
                continue;
            }

            logger.err(err, @errorReturnTrace());
            try connection_writer.interface.writeAll("-ERR something went wrong\r\n");
            return;
        };

        const serialized_result = serializer.serialize(req_allocator, result) catch |err| {
            logger.err(err, @errorReturnTrace());
            try connection_writer.interface.writeAll("-ERR something went wrong\r\n");
            return;
        };

        defer serializer.deinit(req_allocator, serialized_result);

        // Write serialized string
        try connection_writer.interface.writeAll(serialized_result);
    }
}

test "buffer allocation failure is reported once and closes the connection" {
    const CloseRecorder = struct {
        calls: usize = 0,

        fn close(userdata: ?*anyopaque, handles: []const std.Io.net.Socket.Handle) void {
            const self: *@This() = @ptrCast(@alignCast(userdata));
            self.calls += handles.len;
        }
    };

    var close_recorder: CloseRecorder = .{};
    var io_vtable = std.testing.io.vtable.*;
    io_vtable.netClose = CloseRecorder.close;
    const io: std.Io = .{
        .userdata = &close_recorder,
        .vtable = &io_vtable,
    };

    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 0,
    });
    var test_logger = logging.TestLogger.init();
    var unused_store: store.Store = undefined;

    handle(
        io,
        test_logger.logger(),
        .{ .socket = .{ .handle = 1, .address = undefined } },
        &unused_store,
        failing_allocator.allocator(),
        1024,
    );

    const events = test_logger.recordedEvents();
    try std.testing.expectEqual(1, events.len);
    try std.testing.expectEqual(logging.TestLogger.Event.Kind.err, events[0].kind);
    try std.testing.expectEqual(error.OutOfMemory, events[0].source.?);
    try std.testing.expectEqual(1, close_recorder.calls);
}
