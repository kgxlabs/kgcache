const std = @import("std");
const resp = @import("resp.zig");
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

        // TODO: use buffered writer
        var connection_writer = connection.writer(io, &.{});
        var data = [_][]u8{buf};

        // TODO: We are directly doing syscall to OS which is expensive. Refactor this to use buffered reader
        const bytes_read = io.vtable.netRead(io.userdata, connection.socket.handle, &data) catch |err| {
            if (stop_requested.load(.acquire)) return;
            switch (err) {
                error.ConnectionResetByPeer => return,
                else => return err,
            }
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
            if (err == error.OutOfMemory) {
                logger.err("connection: request parsing failed", err, @errorReturnTrace());
                _ = writeResponse(logger, &connection_writer, internal_error_response, stop_requested);
            } else {
                _ = writeResponse(logger, &connection_writer, parseErrorResponse(err), stop_requested);
            }
            return;
        };
        defer parser.deinit(req_allocator, commands);

        const c = commander.init(req_allocator, commands) catch |err| {
            const response = initErrorResponse(err, commands) orelse {
                logger.err("connection: command initialization failed", err, @errorReturnTrace());
                _ = writeResponse(logger, &connection_writer, internal_error_response, stop_requested);
                return;
            };
            if (!writeResponse(logger, &connection_writer, response, stop_requested)) return;
            continue;
        };
        defer c.deinit();

        // TODO: There is a potential memory leak when error occurs.
        // This is the scenario: error can happens when serializing a RESP value and there are some items already allocated.
        // How do we handle that scenario to free the memory?

        var result = c.execute(io, data_store, &client_state) catch |err| {
            if (executeErrorResponse(err, commands)) |response| {
                if (!writeResponse(logger, &connection_writer, response, stop_requested)) return;
                continue;
            }

            logger.err("connection: command execution failed", err, @errorReturnTrace());
            _ = writeResponse(logger, &connection_writer, internal_error_response, stop_requested);
            return;
        };
        defer result.deinit();

        const serialized_result = serializer.serialize(req_allocator, result.value) catch |err| {
            logger.err("connection: response serialization failed", err, @errorReturnTrace());
            _ = writeResponse(logger, &connection_writer, internal_error_response, stop_requested);
            return;
        };

        defer serializer.deinit(req_allocator, serialized_result);

        // Write serialized string
        if (!writeResponse(logger, &connection_writer, serialized_result, stop_requested)) return;
    }
}

const internal_error_response = "-ERR something went wrong\r\n";

fn parseErrorResponse(err: resp.ParseError) []const u8 {
    return switch (err) {
        error.Incomplete => "-ERR protocol error: incomplete request\r\n",
        error.MalformedSize => "-ERR protocol error: malformed size\r\n",
        error.InvalidType => "-ERR protocol error: invalid RESP type\r\n",
        error.IncorrectToken => "-ERR protocol error: incorrect token\r\n",
        error.NotInteger => "-ERR protocol error: invalid integer\r\n",
        error.Malformed => "-ERR protocol error: malformed request\r\n",
        error.ExceededSize => "-ERR protocol error\r\n",
        error.OutOfMemory => unreachable,
    };
}

fn writeResponse(
    logger: logging.Logger,
    writer: *std.Io.net.Stream.Writer,
    bytes: []const u8,
    stop_requested: *const std.atomic.Value(bool),
) bool {
    writer.interface.writeAll(bytes) catch |err| {
        if (!stop_requested.load(.acquire)) {
            logger.err("connection: response write failed", writer.err orelse err, @errorReturnTrace());
        }
        return false;
    };
    return true;
}

fn initErrorResponse(err: commander.Error, request: resp.RESPValue) ?[]const u8 {
    return switch (err) {
        error.UnknownCommand => "-ERR unknown command\r\n",
        error.UnsupportedKeyword => "-ERR unsupported command keyword\r\n",
        error.UnsupportedArgumentType => "-ERR unsupported argument type\r\n",
        error.MalformedCommandRequest => "-ERR malformed command request\r\n",
        error.WrongNumberArguments => wrongNumberArgumentsResponse(request),
        else => null,
    };
}

fn executeErrorResponse(err: anyerror, request: resp.RESPValue) ?[]const u8 {
    return switch (err) {
        error.UnknownCommand => "-ERR unknown command\r\n",
        error.UnsupportedKeyword => "-ERR unsupported command keyword\r\n",
        error.UnsupportedArgumentType => "-ERR unsupported argument type\r\n",
        error.MalformedCommandRequest => "-ERR malformed command request\r\n",
        error.WrongNumberArguments => wrongNumberArgumentsResponse(request),
        error.DbIndexOutOfRange => "-ERR DB index is out of range\r\n",
        error.UnsupportedOption => "-ERR unsupported option\r\n",
        error.Syntax => "-ERR syntax error\r\n",
        error.SaveAlreadyInProgress => "-ERR save already in progress\r\n",
        error.RewriteAlreadyInProgress => "-ERR rewrite already in progress\r\n",
        error.UnsupportedCondition => "-ERR unsupported condition\r\n",
        error.JournalWriteBlocked => "-ERR AOF write is blocked\r\n",
        error.AofDisabled => "-ERR AOF is disabled\r\n",
        else => null,
    };
}

fn wrongNumberArgumentsResponse(request: resp.RESPValue) []const u8 {
    return if (usesLegacyArgumentResponse(request))
        "-Wrong number of arguments\r\n"
    else
        "-ERR wrong number of arguments\r\n";
}

// These commands sent this exact wire response before validation moved here.
fn usesLegacyArgumentResponse(request: resp.RESPValue) bool {
    const values = switch (request) {
        .array => |maybe_values| maybe_values orelse return false,
        else => return false,
    };
    if (values.len == 0) return false;
    const keyword = switch (values[0]) {
        .bulk_string => |maybe_keyword| maybe_keyword orelse return false,
        else => return false,
    };
    return std.ascii.eqlIgnoreCase(keyword, "DBSIZE") or
        std.ascii.eqlIgnoreCase(keyword, "SELECT") or
        std.ascii.eqlIgnoreCase(keyword, "COMMAND") or
        std.ascii.eqlIgnoreCase(keyword, "ECHO");
}
