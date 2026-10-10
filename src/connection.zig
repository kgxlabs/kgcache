const std = @import("std");
const protocol = @import("protocol.zig");
const request_decoder = protocol.request_decoder;
const commander = @import("commander.zig");
const ClientState = @import("client_state.zig");
const store = @import("store.zig");
const logging = @import("logger.zig");

const InputBuffer = struct {
    bytes: []u8,
    read_pos: usize = 0,
    write_pos: usize = 0,

    fn init(allocator: std.mem.Allocator, capacity: usize) std.mem.Allocator.Error!InputBuffer {
        return .{ .bytes = try allocator.alloc(u8, capacity) };
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

/// Serves one client session using a borrowed stream.
///
/// The caller owns the stream and must close it after this function returns.
/// Thread creation, shutdown, joining, and worker reaping belong outside this
/// lower-level connection boundary.
pub fn serve(
    io: std.Io,
    logger: logging.Logger,
    connection: std.Io.net.Stream,
    data_store: *store.Store,
    con_allocator: std.mem.Allocator,
    connection_buffer_size: usize,
    stop_requested: *const std.atomic.Value(bool),
) void {
    if (stop_requested.load(.acquire)) return;

    var buffer = InputBuffer.init(con_allocator, connection_buffer_size) catch |err| {
        logger.err("connection: failed to allocate buffer", err, @errorReturnTrace());
        return;
    };
    defer buffer.deinit(con_allocator);

    handleConnection(io, logger, connection, data_store, &buffer, stop_requested) catch |err| {
        logger.err("connection: request handling failed", err, @errorReturnTrace());
    };
}

const transition_limits: request_decoder.Limits = .{
    .max_frame_bytes = std.math.maxInt(usize),
    .max_elements = std.math.maxInt(usize),
};

fn handleConnection(
    io: std.Io,
    logger: logging.Logger,
    connection: std.Io.net.Stream,
    data_store: *store.Store,
    buffer: *InputBuffer,
    stop_requested: *const std.atomic.Value(bool),
) !void {
    var client_state = ClientState.init();
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

        var connection_writer = connection.writer(io, &.{});
        if (buffer.write_pos == buffer.bytes.len) {
            _ = writeResponse(logger, client_state.resp, &connection_writer, .{ .error_reply = "ERR protocol error: incomplete request" }, stop_requested);
            return;
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

        buffer.write_pos = std.math.add(usize, buffer.write_pos, bytes_read) catch return error.LengthOverflow;
        buffer.assertValid();

        pending: while (buffer.read_pos < buffer.write_pos) {
            if (stop_requested.load(.acquire)) return;

            const consumed = request: {
                var gpa: std.heap.DebugAllocator(.{}) = .init;
                defer _ = gpa.deinit();

                const allocator = gpa.allocator();
                const outcome = request_decoder.decode(buffer.bytes[buffer.read_pos..buffer.write_pos], allocator, transition_limits) catch |err| {
                    if (err == error.OutOfMemory) {
                        logger.err("connection: request parsing failed", err, @errorReturnTrace());
                        _ = writeResponse(logger, client_state.resp, &connection_writer, .{ .error_reply = internal_error_message }, stop_requested);
                    } else {
                        _ = writeResponse(logger, client_state.resp, &connection_writer, .{ .error_reply = parseErrorResponse(err) }, stop_requested);
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
    writer: *std.Io.net.Stream.Writer,
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

    var result = command.execute(io, data_store, client_state) catch |err| {
        if (executeErrorResponse(err)) |message| {
            return writeResponse(logger, client_state.resp, writer, .{ .error_reply = message }, stop_requested);
        }
        logger.err("connection: command execution failed", err, @errorReturnTrace());
        _ = writeResponse(logger, client_state.resp, writer, .{ .error_reply = internal_error_message }, stop_requested);
        return false;
    };
    defer result.deinit();

    return writeResponse(logger, client_state.resp, writer, result.value, stop_requested);
}

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
    writer: *std.Io.net.Stream.Writer,
    value: protocol.Reply,
    stop_requested: *const std.atomic.Value(bool),
) bool {
    selected.writeReply(&writer.interface, value) catch |err| {
        if (err == error.InvalidLineText or err == error.LengthOverflow) {
            logger.err("connection: response encoding failed", err, @errorReturnTrace());

            selected.writeReply(&writer.interface, .{ .error_reply = internal_error_message }) catch |write_err| {
                if (!stop_requested.load(.acquire)) logger.err("connection: response write failed", writer.err orelse write_err, @errorReturnTrace());
                return false;
            };

            writer.interface.flush() catch |flush_err| {
                if (!stop_requested.load(.acquire)) logger.err("connection: response write failed", writer.err orelse flush_err, @errorReturnTrace());
                return false;
            };

            return false;
        }

        if (!stop_requested.load(.acquire)) logger.err("connection: response write failed", writer.err orelse err, @errorReturnTrace());

        return false;
    };

    writer.interface.flush() catch |err| {
        if (!stop_requested.load(.acquire)) logger.err("connection: response write failed", writer.err orelse err, @errorReturnTrace());

        return false;
    };

    return true;
}

fn initErrorResponse(err: commander.Error) ?[]const u8 {
    return switch (err) {
        error.UnknownCommand => "ERR unknown command",
        error.UnsupportedKeyword => "ERR unsupported command keyword",
        error.UnsupportedArgumentType => "ERR unsupported argument type",
        error.MalformedCommandRequest => "ERR malformed command request",
        error.WrongNumberArguments => "ERR wrong number of arguments",
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
        error.Syntax => "ERR syntax error",
        error.SaveAlreadyInProgress => "ERR save already in progress",
        error.RewriteAlreadyInProgress => "ERR rewrite already in progress",
        error.UnsupportedCondition => "ERR unsupported condition",
        error.JournalWriteBlocked => "ERR AOF write is blocked",
        error.AofDisabled => "ERR AOF is disabled",
        else => null,
    };
}
