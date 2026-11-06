const std = @import("std");
const protocol = @import("../protocol.zig");
const request_decoder = protocol.request_decoder;
const commander = @import("../commander.zig");
const ClientRegistry = @import("client_registry.zig");
const ClientState = @import("client_state.zig");
const ConnectionContext = @import("context.zig");
const ConnectionReport = @import("report.zig");
const store = @import("../store.zig");
const logging = @import("../logger.zig");

const ClientSession = @This();

_io: std.Io,
_allocator: std.mem.Allocator,
_data_store: *store.Store,
_stream: std.Io.net.Stream,
_logger: logging.Logger,
_context: ConnectionContext,
_buffer_size: usize,
_buffer: InputBuffer,
_registry: *ClientRegistry,
// this is basically metada data of client session and registry owns it
_record: *ClientRegistry.ClientRecord,

// TODO: Implement
pub fn init(self: *ClientSession, io: std.Io, allocator: std.mem.Allocator, data_store: *store.Store, logger: logging.Logger, stream: std.Io.net.Stream, metadata: ClientRegistry.Metadata, registry: *ClientRegistry, buffer_size: usize) !void {
    var buffer = try InputBuffer.init(allocator, buffer_size);
    errdefer buffer.deinit(allocator);
    const record = try registry.register(io, metadata);

    self.* = .{
        ._io = io,
        ._allocator = allocator,
        ._data_store = data_store,
        ._logger = logger,
        ._stream = stream,
        ._context = ConnectionContext.init(record.id, self, &context_vtable),
        ._buffer = buffer,
        ._buffer_size = buffer_size,
        ._registry = registry,
        ._record = record,
    };
}

// TODO: Implement
pub fn deinit(self: *ClientSession) !void {
    self._buffer.deinit(self._allocator);
}

/// Serves one client session using a borrowed stream.
///
/// The caller owns the stream and must close it after this function returns.
/// Thread creation, shutdown, joining, and worker reaping belong outside this
/// lower-level connection boundary.
pub fn serve(stop_requested: *const std.atomic.Value(bool)) void {
    if (stop_requested.load(.acquire)) return;

    var buffer = InputBuffer.init(con_allocator, connection_buffer_size) catch |err| {
        logger.err("connection: failed to allocate buffer", err, @errorReturnTrace());
        return;
    };
    defer buffer.deinit(con_allocator);

    handleConnection(io, logger, connection, context, data_store, con_allocator, &buffer, stop_requested) catch |err| {
        logger.err("connection: request handling failed", err, @errorReturnTrace());
    };
}

// exposing via getter since we dont want the caller to make overriding to the :worker
pub fn context(self: *ClientSession) *const ConnectionContext {
    return &self._context;
}

const context_vtable: ConnectionContext.VTable = .{
    .snapshot_current = snapshotCurrent,
    .snapshot_live = snapshotLive,
    .record_read = recordRead,
    .record_write = recordWrite,
    .record_dispatch = recordDispatch,
    .record_db_and_proto = recordDbAndProto,
    .set_library_info = setLibraryInfo,
};

fn recordRead(ptr: *anyopaque, byte_count: u64, at: std.Io.Timestamp) void {
    const self: *ClientSession = @ptrCast(@alignCast(ptr));
    self._record.report.recordRead(byte_count, at);
}

fn recordWrite(ptr: *anyopaque, byte_count: u64, at: std.Io.Timestamp) void {
    const self: *ClientSession = @ptrCast(@alignCast(ptr));
    self._record.report.recordWrite(byte_count, at);
}

fn recordDispatch(ptr: *anyopaque, canonical_name: []const u8) void {
    const self: *ClientSession = @ptrCast(@alignCast(ptr));
    self._record.report.recordDispatch(canonical_name);
}

fn recordDbAndProto(ptr: *anyopaque, db_index: u32, resp: protocol.Resp.Version) void {
    const self: *ClientSession = @ptrCast(@alignCast(ptr));
    self._record.report.recordDbAndProto(db_index, resp);
}

fn setLibraryInfo(ptr: *anyopaque, attribute: ConnectionReport.LibraryAttribute, value: []const u8) ConnectionContext.Error!void {
    const self: *ClientSession = @ptrCast(@alignCast(ptr));
    return self._record.report.setLibraryInfo(attribute, value);
}

fn snapshotCurrent(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator) ConnectionContext.Error!ConnectionContext.Snapshot {
    const self: *ClientSession = @ptrCast(@alignCast(ptr));
    const record = self._record;
    const sampled_at = std.Io.Clock.awake.now(io);

    return .{
        .id = record.id,
        .peer_endpoint = record.peer_endpoint,
        .local_endpoint = record.local_endpoint,
        .descriptor = record.descriptor,
        .registered_at = record.registered_at,
        .sampled_at = sampled_at,
        .report = try record.report.snapshot(allocator),
    };
}

fn snapshotLive(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator) ConnectionContext.Error!ConnectionContext.LiveSnapshots {
    const self: *ClientSession = @ptrCast(@alignCast(ptr));
    return self._registry.snapshotLive(io, allocator);
}

fn handleConnection(
    io: std.Io,
    logger: logging.Logger,
    connection: std.Io.net.Stream,
    context: *const ConnectionContext,
    data_store: *store.Store,
    con_allocator: std.mem.Allocator,
    buffer: *InputBuffer,
    stop_requested: *const std.atomic.Value(bool),
) !void {
    var client_state = ClientState.initWithConnection(context);
    while (true) {
        if (stop_requested.load(.acquire)) return;

        if (buffer.read_pos == buffer.write_pos) {
            buffer.read_pos = 0;
            buffer.write_pos = 0;
        }
        buffer.assertValid();

        if (buffer.write_pos == buffer.bytes.len and buffer.read_pos > 0) {
            // The previous frame scopes have released all input borrowers.
            const pending_len = buffer.write_pos - buffer.read_pos;
            @memmove(buffer.bytes[0..pending_len], buffer.bytes[buffer.read_pos..buffer.write_pos]);
            buffer.read_pos = 0;
            buffer.write_pos = pending_len;
            buffer.assertValid();
        }

        var connection_writer: ConnectionWriter = .{
            .io = io,
            .descriptor = connection.socket.handle,
            .context = context,
        };

        if (buffer.write_pos == buffer.bytes.len) {
            buffer.grow(con_allocator) catch |err| {
                if (err == error.OutOfMemory) {
                    logger.err("connection: input buffer growth failed", err, @errorReturnTrace());
                    _ = writeResponse(logger, client_state.resp, &connection_writer, .{ .error_reply = internal_error_message }, stop_requested);
                } else {
                    _ = writeResponse(logger, client_state.resp, &connection_writer, .{ .error_reply = parseErrorResponse(err) }, stop_requested);
                }
                return;
            };
        }

        var data = [_][]u8{buffer.bytes[buffer.write_pos..]};
        const bytes_read = io.vtable.netRead(io.userdata, connection.socket.handle, &data) catch |err| {
            if (stop_requested.load(.acquire)) return;
            switch (err) {
                error.ConnectionResetByPeer => return,
                else => return err,
            }
        };

        if (bytes_read == 0) return;
        // record successfully read bytes
        context.recordRead(io, bytes_read);

        buffer.write_pos = std.math.add(usize, buffer.write_pos, bytes_read) catch return error.LengthOverflow;
        buffer.assertValid();

        pending: while (buffer.read_pos < buffer.write_pos) {
            if (stop_requested.load(.acquire)) return;

            const consumed = request: {
                var gpa: std.heap.DebugAllocator(.{}) = .init;
                defer _ = gpa.deinit();

                const allocator = gpa.allocator();
                const outcome = request_decoder.decode(
                    buffer.bytes[buffer.read_pos..buffer.write_pos],
                    allocator,
                    request_decoder.network_limits,
                ) catch |err| {
                    if (err == error.OutOfMemory) {
                        logger.err("connection: request parsing failed", err, @errorReturnTrace());
                        _ = writeResponse(
                            logger,
                            client_state.resp,
                            &connection_writer,
                            .{ .error_reply = internal_error_message },
                            stop_requested,
                        );
                    } else {
                        _ = writeResponse(
                            logger,
                            client_state.resp,
                            &connection_writer,
                            .{ .error_reply = parseErrorResponse(err) },
                            stop_requested,
                        );
                    }
                    return;
                };

                var decoded = switch (outcome) {
                    .complete => |complete| complete,
                    .incomplete => break :pending,
                };
                defer decoded.deinit(allocator);

                const successful = handleCompleteFrame(
                    io,
                    logger,
                    &connection_writer,
                    data_store,
                    &client_state,
                    allocator,
                    decoded.frame,
                    stop_requested,
                );
                if (!successful) return;

                break :request decoded.consumed;
            };

            buffer.read_pos = std.math.add(usize, buffer.read_pos, consumed) catch return error.LengthOverflow;
            buffer.assertValid();
        }
    }
}

fn handleCompleteFrame(
    io: std.Io,
    logger: logging.Logger,
    writer: *ConnectionWriter,
    data_store: *store.Store,
    client_state: *ClientState,
    allocator: std.mem.Allocator,
    frame: protocol.CommandFrame,
    stop_requested: *const std.atomic.Value(bool),
) bool {
    const command = commander.init(allocator, frame) catch |err| {
        const message = initErrorResponse(err) orelse {
            logger.err("connection: command initialization failed", err, @errorReturnTrace());
            _ = writeResponse(logger, client_state.resp, writer, .{ .error_reply = internal_error_message }, stop_requested);
            return false;
        };

        return writeResponse(logger, client_state.resp, writer, .{ .error_reply = message }, stop_requested);
    };
    defer command.deinit();

    // record command count
    if (client_state.connection_context) |context| context.recordDispatch(command.canonical_name);

    var result = command.execute(io, data_store, client_state) catch |err| {
        if (executeErrorResponse(err)) |message| {
            if (client_state.connection_context) |context| context.recordDbAndProto(
                client_state.db_index,
                client_state.resp.version(),
            );

            return writeResponse(logger, client_state.resp, writer, .{ .error_reply = message }, stop_requested);
        }

        logger.err("connection: command execution failed", err, @errorReturnTrace());
        _ = writeResponse(logger, client_state.resp, writer, .{ .error_reply = internal_error_message }, stop_requested);

        return false;
    };
    defer result.deinit();

    if (client_state.connection_context) |context| context.recordDbAndProto(
        client_state.db_index,
        client_state.resp.version(),
    );

    return writeResponse(logger, client_state.resp, writer, result.value, stop_requested);
}

const ConnectionWriter = struct {
    io: std.Io,
    descriptor: std.Io.net.Socket.Handle,
    context: *const ConnectionContext,
    interface: std.Io.Writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },
    err: ?std.Io.net.Stream.Writer.Error = null,

    fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *ConnectionWriter = @alignCast(@fieldParentPtr("interface", writer));
        const count = self.io.vtable.netWrite(self.io.userdata, self.descriptor, writer.buffered(), data, splat) catch |err| {
            self.err = err;
            return error.WriteFailed;
        };

        self.context.recordWrite(self.io, count);

        return writer.consume(count);
    }
};

const InputBuffer = struct {
    bytes: []u8,
    read_pos: usize = 0,
    write_pos: usize = 0,

    fn init(allocator: std.mem.Allocator, capacity: usize) std.mem.Allocator.Error!InputBuffer {
        return .{ .bytes = try allocator.alloc(u8, @min(capacity, request_decoder.network_limits.max_frame_bytes)) };
    }

    fn grow(self: *InputBuffer, allocator: std.mem.Allocator) (std.mem.Allocator.Error || error{FrameTooLarge})!void {
        self.assertValid();
        const max_capacity = request_decoder.network_limits.max_frame_bytes;
        if (self.bytes.len >= max_capacity) return error.FrameTooLarge;

        const doubled = std.math.mul(usize, @max(self.bytes.len, 1), 2) catch max_capacity;
        const new_capacity = @min(doubled, max_capacity);
        self.bytes = try allocator.realloc(self.bytes, new_capacity);
        self.assertValid();
    }

    fn deinit(self: *InputBuffer, allocator: std.mem.Allocator) void {
        self.assertValid();
        allocator.free(self.bytes);
        self.* = undefined;
    }

    fn assertValid(self: *const InputBuffer) void {
        std.debug.assert(self.read_pos <= self.write_pos);
        std.debug.assert(self.write_pos <= self.bytes.len);
    }
};

const internal_error_message = "ERR something went wrong";

fn parseErrorResponse(err: request_decoder.DecodeError) []const u8 {
    return switch (err) {
        error.ExpectedArray, error.ExpectedBulkString => "ERR protocol error: invalid RESP type",
        error.EmptyArray, error.InvalidArrayLength => "ERR protocol error: malformed request",
        error.InvalidBulkLength, error.LengthOverflow => "ERR protocol error: malformed size",
        error.InvalidLineEnding, error.InvalidBulkTerminator => "ERR protocol error: malformed request",
        error.FrameTooLarge, error.TooManyElements, error.ArgumentTableTooLarge => "ERR protocol error: request limit exceeded",
        error.OutOfMemory => unreachable,
    };
}

fn writeResponse(
    logger: logging.Logger,
    selected: protocol.Resp,
    writer: *ConnectionWriter,
    value: protocol.Reply,
    stop_requested: *const std.atomic.Value(bool),
) bool {
    selected.writeReply(&writer.interface, value) catch |err| {
        if (err == error.InvalidLineText or err == error.LengthOverflow) {
            logger.err("connection: response encoding failed", err, @errorReturnTrace());

            selected.writeReply(&writer.interface, .{ .error_reply = internal_error_message }) catch |write_err| {
                reportWriteFailure(logger, writer.err orelse write_err, @errorReturnTrace(), stop_requested);
                return false;
            };

            writer.interface.flush() catch |flush_err| {
                reportWriteFailure(logger, writer.err orelse flush_err, @errorReturnTrace(), stop_requested);
                return false;
            };

            return false;
        }

        reportWriteFailure(logger, writer.err orelse err, @errorReturnTrace(), stop_requested);

        return false;
    };

    writer.interface.flush() catch |err| {
        reportWriteFailure(logger, writer.err orelse err, @errorReturnTrace(), stop_requested);

        return false;
    };

    return true;
}

fn reportWriteFailure(
    logger: logging.Logger,
    source: anyerror,
    trace: logging.Logger.ErrorTrace,
    stop_requested: *const std.atomic.Value(bool),
) void {
    if (stop_requested.load(.acquire)) return;
    switch (source) {
        // The stream writer reports a socket broken pipe as SocketUnconnected.
        error.ConnectionResetByPeer, error.SocketUnconnected => return,
        else => logger.err("connection: response write failed", source, trace),
    }
}

fn initErrorResponse(err: commander.Error) ?[]const u8 {
    return switch (err) {
        error.UnknownCommand => "ERR unknown command",
        error.UnsupportedKeyword => "ERR unsupported command keyword",
        error.UnsupportedArgumentType => "ERR unsupported argument type",
        error.MalformedCommandRequest => "ERR malformed command request",
        error.WrongNumberArguments => "ERR wrong number of arguments",
        error.UnsupportedOption => "ERR unsupported option",
        else => null,
    };
}

fn executeErrorResponse(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.UnknownCommand => "ERR unknown command",
        error.UnsupportedKeyword => "ERR unsupported command keyword",
        error.UnsupportedArgumentType => "ERR unsupported argument type",
        error.MalformedCommandRequest => "ERR malformed command request",
        error.WrongNumberArguments => "ERR wrong number of arguments",
        error.DbIndexOutOfRange => "ERR DB index is out of range",
        error.UnsupportedOption => "ERR unsupported option",
        error.UnsupportedProtocolVersion => "NOPROTO unsupported protocol version",
        error.Syntax => "ERR syntax error",
        error.SaveAlreadyInProgress => "ERR save already in progress",
        error.RewriteAlreadyInProgress => "ERR rewrite already in progress",
        error.UnsupportedCondition => "ERR unsupported condition",
        error.JournalWriteBlocked => "ERR AOF write is blocked",
        error.AofDisabled => "ERR AOF is disabled",
        else => null,
    };
}

test "handler creation failures preserve the previous session dispatch" {
    try @import("session_tests.zig").checkHandlerCreationFailures(ConnectionWriter, handleCompleteFrame);
}
