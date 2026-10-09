const std = @import("std");
const protocol = @import("protocol.zig");
const request_decoder = protocol.request_decoder;
const commander = @import("commander.zig");
const ClientState = @import("client_state.zig");
const store = @import("store.zig");
const logging = @import("logger.zig");

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

    const buf = con_allocator.alloc(u8, connection_buffer_size) catch |err| {
        logger.err("connection: failed to allocate buffer", err, @errorReturnTrace());
        return;
    };
    defer con_allocator.free(buf);

    handleConnection(io, logger, connection, data_store, buf, stop_requested) catch |err| {
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
    buf: []u8,
    stop_requested: *const std.atomic.Value(bool),
) !void {
    var client_state = ClientState.init();
    while (true) {
        if (stop_requested.load(.acquire)) return;

        var connection_writer = connection.writer(io, &.{});
        var data = [_][]u8{buf};
        const bytes_read = io.vtable.netRead(io.userdata, connection.socket.handle, &data) catch |err| {
            if (stop_requested.load(.acquire)) return;
            switch (err) {
                error.ConnectionResetByPeer => return,
                else => return err,
            }
        };

        if (bytes_read == 0) return;

        var cursor: usize = 0;
        while (cursor < bytes_read) {
            const consumed = handleRequest(io, logger, &connection_writer, data_store, &client_state, buf[cursor..bytes_read], stop_requested) orelse return;
            cursor = std.math.add(usize, cursor, consumed) catch return error.LengthOverflow;
        }
    }
}

fn handleRequest(
    io: std.Io,
    logger: logging.Logger,
    writer: *std.Io.net.Stream.Writer,
    data_store: *store.Store,
    client_state: *ClientState,
    input: []const u8,
    stop_requested: *const std.atomic.Value(bool),
) ?usize {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();
    const outcome = request_decoder.decode(input, allocator, transition_limits) catch |err| {
        if (err == error.OutOfMemory) {
            logger.err("connection: request parsing failed", err, @errorReturnTrace());
            _ = writeResponse(logger, client_state.resp, writer, .{ .error_reply = internal_error_message }, stop_requested);
        } else {
            _ = writeResponse(logger, client_state.resp, writer, .{ .error_reply = parseErrorResponse(err) }, stop_requested);
        }
        return null;
    };

    var decoded = switch (outcome) {
        .complete => |complete| complete,
        // TODO: implement incremental framing for the requests
        .incomplete => {
            _ = writeResponse(logger, client_state.resp, writer, .{ .error_reply = "ERR protocol error: incomplete request" }, stop_requested);
            return null;
        },
    };
    defer decoded.deinit(allocator);

    const command = commander.init(allocator, decoded.frame) catch |err| {
        const message = initErrorResponse(err) orelse {
            logger.err("connection: command initialization failed", err, @errorReturnTrace());
            _ = writeResponse(logger, client_state.resp, writer, .{ .error_reply = internal_error_message }, stop_requested);
            return null;
        };

        if (!writeResponse(logger, client_state.resp, writer, .{ .error_reply = message }, stop_requested)) return null;

        return decoded.consumed;
    };
    defer command.deinit();

    var result = command.execute(io, data_store, client_state) catch |err| {
        if (executeErrorResponse(err)) |message| {
            if (!writeResponse(logger, client_state.resp, writer, .{ .error_reply = message }, stop_requested)) return null;
            return decoded.consumed;
        }
        logger.err("connection: command execution failed", err, @errorReturnTrace());
        _ = writeResponse(logger, client_state.resp, writer, .{ .error_reply = internal_error_message }, stop_requested);
        return null;
    };
    defer result.deinit();

    if (!writeResponse(logger, client_state.resp, writer, result.value, stop_requested)) return null;

    return decoded.consumed;
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
