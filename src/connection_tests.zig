const std = @import("std");
const store = @import("store.zig");
const logging = @import("logger.zig");
const serve = @import("connection.zig").serve;

const never_stop_requested: std.atomic.Value(bool) = .init(false);

test "buffer allocation failure is reported once without closing the borrowed stream" {
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

    serve(
        io,
        test_logger.logger(),
        .{ .socket = .{ .handle = 1, .address = undefined } },
        &unused_store,
        failing_allocator.allocator(),
        1024,
        &never_stop_requested,
    );

    const events = test_logger.recordedEvents();
    try std.testing.expectEqual(1, events.len);
    try std.testing.expectEqual(logging.TestLogger.Event.Kind.err, events[0].kind);
    try std.testing.expectEqual(error.OutOfMemory, events[0].source.?);
    try std.testing.expectEqual(0, close_recorder.calls);
}

const TestConnectionIo = struct {
    requests: []const []const u8,
    next_request: usize = 0,
    request_offset: usize = 0,
    output: [512]u8 = undefined,
    output_len: usize = 0,
    close_calls: usize = 0,
    fail_write: bool = false,
    fail_after_bytes: ?usize = null,
    max_write_bytes: usize = std.math.maxInt(usize),
    stop_after_read: ?*std.atomic.Value(bool) = null,
    stop_during_write: ?*std.atomic.Value(bool) = null,
    vtable: std.Io.VTable = undefined,

    fn io(self: *@This()) std.Io {
        self.vtable = std.testing.io.vtable.*;
        self.vtable.netRead = read;
        self.vtable.netWrite = write;
        self.vtable.netClose = close;
        return .{ .userdata = self, .vtable = &self.vtable };
    }

    fn read(ptr: ?*anyopaque, _: std.Io.net.Socket.Handle, data: [][]u8) std.Io.net.Stream.Reader.Error!usize {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (self.next_request == self.requests.len) return 0;
        const request = self.requests[self.next_request];
        std.debug.assert(data[0].len > 0);
        const count = @min(request.len - self.request_offset, data[0].len);
        @memcpy(data[0][0..count], request[self.request_offset..][0..count]);
        self.request_offset += count;
        if (self.request_offset == request.len) {
            self.next_request += 1;
            self.request_offset = 0;
        }
        if (self.stop_after_read) |flag| flag.store(true, .release);
        return count;
    }

    fn write(ptr: ?*anyopaque, _: std.Io.net.Socket.Handle, header: []const u8, data: []const []const u8, splat: usize) std.Io.net.Stream.Writer.Error!usize {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (self.fail_write) return error.NetworkDown;
        if (self.fail_after_bytes) |limit| {
            if (self.output_len >= limit) return error.NetworkDown;
        }
        if (self.stop_during_write) |flag| flag.store(true, .release);
        var remaining = self.max_write_bytes;
        std.debug.assert(remaining > 0);
        var count = self.append(header, &remaining);
        if (count != header.len) return count;
        for (data[0 .. data.len - 1]) |part| {
            const byte_count = self.append(part, &remaining);
            count += byte_count;
            if (byte_count != part.len) return count;
        }
        if (splat > 0) {
            const part = data[data.len - 1];
            for (0..splat) |_| {
                const byte_count = self.append(part, &remaining);
                count += byte_count;
                if (byte_count != part.len) return count;
            }
        }
        return count;
    }

    fn append(self: *@This(), bytes: []const u8, remaining: *usize) usize {
        const limit = self.fail_after_bytes orelse self.output.len;
        const count = @min(bytes.len, limit - self.output_len, remaining.*);
        std.debug.assert(self.output_len + count <= self.output.len);
        @memcpy(self.output[self.output_len..][0..count], bytes[0..count]);
        self.output_len += count;
        remaining.* -= count;
        return count;
    }

    fn close(ptr: ?*anyopaque, handles: []const std.Io.net.Socket.Handle) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.close_calls += handles.len;
    }

    fn written(self: *const @This()) []const u8 {
        return self.output[0..self.output_len];
    }
};

test "a Storage source crosses Store and Commander to the connection logger" {
    const testing = std.testing;
    const Storage = @import("storage/interface.zig");
    const DefaultStorage = @import("storage/default_storage.zig");
    const PersistenceState = @import("persistence_state.zig");
    const persistence = @import("persistence.zig");
    var fake_io: TestConnectionIo = .{ .requests = &.{"*1\r\n$6\r\nDBSIZE\r\n*1\r\n$4\r\nPING\r\n"} };
    var test_logger = logging.TestLogger.init();

    var backend = DefaultStorage.init(testing.io, testing.allocator);
    var fake_storage = backend.storage();
    var fake_vtable = fake_storage.vtable.*;
    fake_vtable.begin = struct {
        fn begin(_: *anyopaque) anyerror!Storage.Tx {
            return error.TestStorageSource;
        }
    }.begin;
    fake_storage.vtable = &fake_vtable;
    var state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });
    var kgc = try persistence.KgcPersistence.init(testing.io, testing.allocator, &state, "scratch-storage-source.kgc");
    var memory_store = store.MemoryStore.init(testing.allocator, &.{fake_storage}, kgc.snapshot(), null);
    var data_store = memory_store.store();
    defer data_store.deinit();

    serve(fake_io.io(), test_logger.logger(), .{ .socket = .{ .handle = 1, .address = undefined } }, &data_store, testing.allocator, 1024, &never_stop_requested);

    try testing.expectEqualStrings("-ERR something went wrong\r\n", fake_io.written());
    try testing.expectEqual(0, fake_io.close_calls);
    const events = test_logger.recordedEvents();
    try testing.expectEqual(1, events.len);
    try testing.expectEqual(error.TestStorageSource, events[0].source.?);
}

test "argument count errors use ERR for every command and allow another request" {
    const testing = std.testing;
    const requests = [_][]const u8{
        "*2\r\n$12\r\nBGREWRITEAOF\r\n$1\r\nx\r\n",
        "*3\r\n$6\r\nBGSAVE\r\n$8\r\nSCHEDULE\r\n$1\r\nx\r\n",
        "*2\r\n$6\r\nDBSIZE\r\n$1\r\nx\r\n",
        "*1\r\n$3\r\nDEL\r\n",
        "*1\r\n$4\r\nECHO\r\n",
        "*1\r\n$3\r\nGET\r\n",
        "*3\r\n$4\r\nPING\r\n$1\r\nx\r\n$1\r\ny\r\n",
        "*2\r\n$4\r\nSAVE\r\n$1\r\nx\r\n",
        "*1\r\n$6\r\nSELECT\r\n",
        "*2\r\n$3\r\nSET\r\n$3\r\nkey\r\n",
        "*3\r\n$7\r\nCOMMAND\r\n$5\r\nCOUNT\r\n$1\r\nx\r\n",
    };

    for (requests) |request| {
        var fake_io: TestConnectionIo = .{ .requests = &.{ request, "*1\r\n$4\r\nPING\r\n" } };
        var test_logger = logging.TestLogger.init();
        var mock = store.MockStore.init();
        var data_store = mock.store();

        serve(fake_io.io(), test_logger.logger(), .{ .socket = .{ .handle = 1, .address = undefined } }, &data_store, testing.allocator, 1024, &never_stop_requested);

        try testing.expectEqualStrings("-ERR wrong number of arguments\r\n+PONG\r\n", fake_io.written());
        try testing.expectEqual(0, test_logger.recordedEvents().len);
    }
}

test "commands preserve replies and database state through a connection" {
    const testing = std.testing;
    const DefaultStorage = @import("storage/default_storage.zig");
    const PersistenceState = @import("persistence_state.zig");
    const persistence = @import("persistence.zig");

    var fake_io: TestConnectionIo = .{ .requests = &.{
        "*3\r\n$3\r\nsEt\r\n$3\r\nkey\r\n$5\r\nvalue\r\n",
        "*2\r\n$3\r\nGET\r\n$3\r\nkey\r\n",
        "*2\r\n$3\r\nSET\r\n$3\r\nkey\r\n",
        "*2\r\n$3\r\nGET\r\n$3\r\nkey\r\n",
        "*1\r\n$3\r\nDEL\r\n",
        "*2\r\n$3\r\nGET\r\n$3\r\nkey\r\n",
        "*1\r\n$6\r\nDBSIZE\r\n",
        "*2\r\n$6\r\nSELECT\r\n$1\r\n1\r\n",
        "*2\r\n$3\r\nGET\r\n$3\r\nkey\r\n",
        "*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$5\r\nother\r\n",
        "*1\r\n$6\r\nDBSIZE\r\n",
        "*2\r\n$6\r\nSELECT\r\n$1\r\n0\r\n",
        "*2\r\n$3\r\nDEL\r\n$3\r\nkey\r\n",
        "*2\r\n$3\r\nGET\r\n$3\r\nkey\r\n",
        "*1\r\n$6\r\nDBSIZE\r\n",
    } };
    var test_logger = logging.TestLogger.init();

    var database_zero = DefaultStorage.init(testing.io, testing.allocator);
    var database_one = DefaultStorage.init(testing.io, testing.allocator);
    var persistence_state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });
    var kgc = try persistence.KgcPersistence.init(
        testing.io,
        testing.allocator,
        &persistence_state,
        "command-registry-behavior.kgc",
    );
    var memory_store = store.MemoryStore.init(
        testing.allocator,
        &.{ database_zero.storage(), database_one.storage() },
        kgc.snapshot(),
        null,
    );
    var data_store = memory_store.store();
    defer data_store.deinit();

    serve(
        fake_io.io(),
        test_logger.logger(),
        .{ .socket = .{ .handle = 1, .address = undefined } },
        &data_store,
        testing.allocator,
        1024,
        &never_stop_requested,
    );

    try testing.expectEqualStrings(
        "+OK\r\n" ++
            "$5\r\nvalue\r\n" ++
            "-ERR wrong number of arguments\r\n" ++
            "$5\r\nvalue\r\n" ++
            "-ERR wrong number of arguments\r\n" ++
            "$5\r\nvalue\r\n" ++
            ":1\r\n" ++
            "+OK\r\n" ++
            "$-1\r\n" ++
            "+OK\r\n" ++
            ":1\r\n" ++
            "+OK\r\n" ++
            ":1\r\n" ++
            "$-1\r\n" ++
            ":0\r\n",
        fake_io.written(),
    );
    try testing.expectEqual(15, fake_io.next_request);
    try testing.expectEqual(0, test_logger.recordedEvents().len);
    try testing.expectEqual(0, fake_io.close_calls);
}

test "a malformed protocol request gets its fixed response without an error event" {
    const testing = std.testing;
    var fake_io: TestConnectionIo = .{ .requests = &.{"?\r\n"} };
    var test_logger = logging.TestLogger.init();
    var mock = store.MockStore.init();
    var data_store = mock.store();

    serve(fake_io.io(), test_logger.logger(), .{ .socket = .{ .handle = 1, .address = undefined } }, &data_store, testing.allocator, 1024, &never_stop_requested);

    try testing.expectEqualStrings("-ERR protocol error: invalid RESP type\r\n", fake_io.written());
    try testing.expectEqual(0, fake_io.close_calls);
    try testing.expectEqual(0, test_logger.recordedEvents().len);
}

test "an unknown command gets its fixed response and the connection continues" {
    const testing = std.testing;
    var fake_io: TestConnectionIo = .{ .requests = &.{
        "*1\r\n$7\r\nUNKNOWN\r\n",
        "*1\r\n$4\r\nPING\r\n",
    } };
    var test_logger = logging.TestLogger.init();
    var mock = store.MockStore.init();
    var data_store = mock.store();

    serve(fake_io.io(), test_logger.logger(), .{ .socket = .{ .handle = 1, .address = undefined } }, &data_store, testing.allocator, 1024, &never_stop_requested);

    try testing.expectEqualStrings("-ERR unknown command\r\n+PONG\r\n", fake_io.written());
    try testing.expectEqual(2, fake_io.next_request);
    try testing.expectEqual(0, test_logger.recordedEvents().len);
}

test "a response write source is reported once without closing the borrowed stream" {
    const testing = std.testing;
    var fake_io: TestConnectionIo = .{ .requests = &.{"*1\r\n$4\r\nPING\r\n"}, .fail_write = true };
    var test_logger = logging.TestLogger.init();
    var mock = store.MockStore.init();
    var data_store = mock.store();

    serve(fake_io.io(), test_logger.logger(), .{ .socket = .{ .handle = 1, .address = undefined } }, &data_store, testing.allocator, 1024, &never_stop_requested);

    try testing.expectEqualStrings("", fake_io.written());
    try testing.expectEqual(0, fake_io.close_calls);
    const events = test_logger.recordedEvents();
    try testing.expectEqual(1, events.len);
    try testing.expectEqual(error.NetworkDown, events[0].source.?);
}

test "an internal failure and failed error response report both sources" {
    const testing = std.testing;
    var fake_io: TestConnectionIo = .{ .requests = &.{"*1\r\n$6\r\nDBSIZE\r\n"}, .fail_write = true };
    var test_logger = logging.TestLogger.init();
    var mock = store.MockStore.init();
    mock.dbsize_result = error.TestStorageSource;
    var data_store = mock.store();

    serve(fake_io.io(), test_logger.logger(), .{ .socket = .{ .handle = 1, .address = undefined } }, &data_store, testing.allocator, 1024, &never_stop_requested);

    try testing.expectEqualStrings("", fake_io.written());
    try testing.expectEqual(0, fake_io.close_calls);
    const events = test_logger.recordedEvents();
    try testing.expectEqual(2, events.len);
    try testing.expectEqual(error.TestStorageSource, events[0].source.?);
    try testing.expectEqual(error.NetworkDown, events[1].source.?);
}

test "complete commands in one read advance after replies and mapped errors" {
    const testing = std.testing;
    var fake_io: TestConnectionIo = .{ .requests = &.{
        "*1\r\n$4\r\nPING\r\n" ++
            "*1\r\n$3\r\nGET\r\n" ++
            "*2\r\n$4\r\nECHO\r\n$3\r\n\x00\r\n\r\n" ++
            "*2\r\n$6\r\nSELECT\r\n$1\r\n9\r\n" ++
            "*1\r\n$6\r\nDBSIZE\r\n",
        "*2\r\n$4\r\nECHO\r\n$0\r\n\r\n",
    } };
    var test_logger = logging.TestLogger.init();
    var mock = store.MockStore.init();
    mock.dbsize_result = 7;
    var data_store = mock.store();

    serve(fake_io.io(), test_logger.logger(), .{ .socket = .{ .handle = 1, .address = undefined } }, &data_store, testing.allocator, 1024, &never_stop_requested);

    try testing.expectEqualStrings(
        "+PONG\r\n-ERR wrong number of arguments\r\n$3\r\n\x00\r\n\r\n-ERR DB index is out of range\r\n:7\r\n$0\r\n\r\n",
        fake_io.written(),
    );
    try testing.expectEqual(1, mock.dbsize_calls);
    try testing.expectEqual(2, fake_io.next_request);
    try testing.expectEqual(0, test_logger.recordedEvents().len);
}

test "fragmented commands finish at every split and unfinished EOF stays quiet" {
    const testing = std.testing;
    const cases = [_]struct { request: []const u8, reply: []const u8, stored_value: ?[]const u8 = null }{
        .{ .request = "*1\r\n$4\r\nPING\r\n", .reply = "+PONG\r\n" },
        .{ .request = "*2\r\n$4\r\nECHO\r\n$3\r\n\x00\r\n\r\n", .reply = "$3\r\n\x00\r\n\r\n" },
        .{ .request = "*2\r\n$4\r\nECHO\r\n$0\r\n\r\n", .reply = "$0\r\n\r\n" },
        .{ .request = "*3\r\n$3\r\nSET\r\n$0\r\n\r\n$5\r\na\x00\r\nb\r\n", .reply = "+OK\r\n", .stored_value = "a\x00\r\nb" },
    };

    for (cases) |case| {
        for (1..case.request.len) |split| {
            var mock = store.MockStore.init();
            var data_store = mock.store();
            var test_logger = logging.TestLogger.init();
            var fake_io: TestConnectionIo = .{ .requests = &.{ case.request[0..split], case.request[split..], "*1\r\n$4\r\nPING\r\n" } };

            serve(fake_io.io(), test_logger.logger(), .{ .socket = .{ .handle = 1, .address = undefined } }, &data_store, testing.allocator, case.request.len, &never_stop_requested);

            var expected_buffer: [64]u8 = undefined;
            const expected = try std.fmt.bufPrint(&expected_buffer, "{s}+PONG\r\n", .{case.reply});
            try testing.expectEqualStrings(expected, fake_io.written());
            if (case.stored_value) |value| {
                try testing.expectEqual(1, mock.set_calls);
                try testing.expectEqualStrings(value, mock.last_set_value_copy[0..mock.last_set_value_len]);
            }
            try testing.expectEqual(0, test_logger.recordedEvents().len);
            try testing.expectEqual(0, fake_io.close_calls);

            var unfinished_mock = store.MockStore.init();
            var unfinished_store = unfinished_mock.store();
            var unfinished_io: TestConnectionIo = .{ .requests = &.{case.request[0..split]} };
            serve(unfinished_io.io(), test_logger.logger(), .{ .socket = .{ .handle = 1, .address = undefined } }, &unfinished_store, testing.allocator, case.request.len, &never_stop_requested);

            try testing.expectEqualStrings("", unfinished_io.written());
            try testing.expectEqual(0, unfinished_mock.set_calls);
            try testing.expectEqual(0, test_logger.recordedEvents().len);
            try testing.expectEqual(0, unfinished_io.close_calls);
        }
    }
}

test "unfinished EOF and malformed pipeline tails preserve earlier replies and stored data" {
    const testing = std.testing;
    const DefaultStorage = @import("storage/default_storage.zig");
    const PersistenceState = @import("persistence_state.zig");
    const persistence = @import("persistence.zig");
    const prefix = "*3\r\n$3\r\nSET\r\n$5\r\nfruit\r\n$5\r\napple\r\n" ++
        "*2\r\n$3\r\nGET\r\n$5\r\nfruit\r\n";
    const later_delete = "*2\r\n$3\r\nDEL\r\n$5\r\nfruit\r\n";
    const cases = [_]struct { tail: []const u8, reply: []const u8 = "" }{
        .{ .tail = "*3\r\n$3\r\nSET\r\n$5\r\nfruit\r\n$6\r\nban" },
        .{ .tail = "*3\r\n$3\r\nSET\r\n$5\r\nfruit\r\n$6\r\nbanana\r" },
        .{ .tail = "*3\r\n$3\r\nDEL\r\n$5\r\nfruit\r\n$5\r\nother\r" },
        .{ .tail = "*x\r\n" ++ later_delete, .reply = "-ERR protocol error: malformed request\r\n" },
        .{ .tail = "*3\r\n$3\r\nSET\r\n$5\r\nfruit\r\n$6\r\nbanana\rX" ++ later_delete, .reply = "-ERR protocol error: malformed request\r\n" },
    };

    for (cases) |case| {
        var request_bytes: [128]u8 = undefined;
        const request = try std.fmt.bufPrint(&request_bytes, "{s}{s}", .{ prefix, case.tail });
        var fake_io: TestConnectionIo = .{ .requests = &.{request} };
        var test_logger = logging.TestLogger.init();
        var backend = DefaultStorage.init(testing.io, testing.allocator);
        var persistence_state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });
        var kgc = try persistence.KgcPersistence.init(testing.io, testing.allocator, &persistence_state, "connection-unfinished-or-malformed-tail.kgc");
        var memory_store = store.MemoryStore.init(testing.allocator, &.{backend.storage()}, kgc.snapshot(), null);
        var data_store = memory_store.store();
        defer data_store.deinit();

        serve(fake_io.io(), test_logger.logger(), .{ .socket = .{ .handle = 1, .address = undefined } }, &data_store, testing.allocator, 36, &never_stop_requested);

        var reply_bytes: [64]u8 = undefined;
        const expected = try std.fmt.bufPrint(&reply_bytes, "+OK\r\n$5\r\napple\r\n{s}", .{case.reply});
        try testing.expectEqualStrings(expected, fake_io.written());
        var stored = (try data_store.get("fruit", 0)).?;
        defer stored.deinit();
        try testing.expectEqualStrings("apple", stored.value.string);
        try testing.expectEqual(1, try data_store.dbsize(0));
        try testing.expectEqual(0, test_logger.recordedEvents().len);
        try testing.expectEqual(0, fake_io.close_calls);
    }
}

test "commands larger than initial capacity finish and allow later commands" {
    const testing = std.testing;
    const echo = "*2\r\n$4\r\nECHO\r\n$1\r\nx\r\n";
    const pipeline = "*1\r\n$4\r\nPING\r\n" ++ echo ++ "*1\r\n$6\r\nDBSIZE\r\n";
    const cases = [_]struct { request: []const u8, capacity: usize, reply: []const u8, dbsize_calls: usize = 0 }{
        .{ .request = echo, .capacity = 14, .reply = "$1\r\nx\r\n" },
        .{ .request = pipeline, .capacity = echo.len - 1, .reply = "+PONG\r\n$1\r\nx\r\n:7\r\n", .dbsize_calls = 1 },
        .{ .request = pipeline, .capacity = echo.len, .reply = "+PONG\r\n$1\r\nx\r\n:7\r\n", .dbsize_calls = 1 },
    };

    for (cases) |case| {
        var fake_io: TestConnectionIo = .{ .requests = &.{case.request} };
        var test_logger = logging.TestLogger.init();
        var mock = store.MockStore.init();
        mock.dbsize_result = 7;
        var data_store = mock.store();

        serve(fake_io.io(), test_logger.logger(), .{ .socket = .{ .handle = 1, .address = undefined } }, &data_store, testing.allocator, case.capacity, &never_stop_requested);

        try testing.expectEqualStrings(case.reply, fake_io.written());
        try testing.expectEqual(case.dbsize_calls, mock.dbsize_calls);
        try testing.expectEqual(0, test_logger.recordedEvents().len);
        try testing.expectEqual(0, fake_io.close_calls);
    }
}

test "input byte limit accepts an exact frame and rejects a one-byte excess" {
    const testing = std.testing;
    const limit = @import("protocol.zig").request_decoder.network_limits.max_frame_bytes;
    const prefix = "*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$";
    const overhead = prefix.len + std.fmt.count("{d}", .{limit}) + "\r\n\r\n".len;

    for ([_]usize{ 0, 1 }) |excess| {
        const value_len = limit - overhead + excess;
        const request = try testing.allocator.alloc(u8, limit + excess);
        defer testing.allocator.free(request);
        const header = try std.fmt.bufPrint(request, prefix ++ "{d}\r\n", .{value_len});
        try testing.expectEqual(request.len, header.len + value_len + 2);
        @memset(request[header.len..][0..value_len], 'x');
        @memcpy(request[request.len - 2 ..], "\r\n");

        for ([_]usize{ 1024, limit * 2 }) |initial_capacity| {
            var fake_io: TestConnectionIo = .{ .requests = &.{
                "*1\r\n$4\r\nPING\r\n",
                request,
                "*1\r\n$6\r\nDBSIZE\r\n",
            } };
            var test_logger = logging.TestLogger.init();
            var mock = store.MockStore.init();
            mock.dbsize_result = 7;
            var data_store = mock.store();

            serve(fake_io.io(), test_logger.logger(), .{ .socket = .{ .handle = 1, .address = undefined } }, &data_store, testing.allocator, initial_capacity, &never_stop_requested);

            if (excess == 0) {
                try testing.expectEqualStrings("+PONG\r\n+OK\r\n:7\r\n", fake_io.written());
                try testing.expectEqual(1, mock.set_calls);
                try testing.expectEqual(1, mock.dbsize_calls);
            } else {
                try testing.expectEqualStrings("+PONG\r\n-ERR protocol error: request limit exceeded\r\n", fake_io.written());
                try testing.expectEqual(0, mock.set_calls);
                try testing.expectEqual(0, mock.dbsize_calls);
            }
            try testing.expectEqual(0, test_logger.recordedEvents().len);
            try testing.expectEqual(0, fake_io.close_calls);
        }
    }
}

test "growth allocation failure preserves earlier mutations and releases input" {
    const testing = std.testing;
    const DefaultStorage = @import("storage/default_storage.zig");
    const PersistenceState = @import("persistence_state.zig");
    const persistence = @import("persistence.zig");
    const value = "banana" ** 24;
    const request = try std.fmt.allocPrint(testing.allocator, "*3\r\n$3\r\nSET\r\n$5\r\nfruit\r\n$5\r\napple\r\n" ++
        "*3\r\n$3\r\nSET\r\n$5\r\nfruit\r\n${d}\r\n{s}\r\n" ++
        "*2\r\n$3\r\nDEL\r\n$5\r\nfruit\r\n", .{ value.len, value });
    defer testing.allocator.free(request);

    for ([_]bool{ false, true }) |fail_error_reply| {
        var fake_io: TestConnectionIo = .{
            .requests = &.{request},
            .fail_after_bytes = if (fail_error_reply) 5 else null,
        };
        var failing_allocator = testing.FailingAllocator.init(testing.allocator, .{
            .fail_index = 1,
            .resize_fail_index = 0,
        });
        var test_logger = logging.TestLogger.init();
        var backend = DefaultStorage.init(testing.io, testing.allocator);
        var persistence_state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });
        var kgc = try persistence.KgcPersistence.init(testing.io, testing.allocator, &persistence_state, "connection-growth-failure.kgc");
        var memory_store = store.MemoryStore.init(testing.allocator, &.{backend.storage()}, kgc.snapshot(), null);
        var data_store = memory_store.store();
        defer data_store.deinit();

        serve(fake_io.io(), test_logger.logger(), .{ .socket = .{ .handle = 1, .address = undefined } }, &data_store, failing_allocator.allocator(), 40, &never_stop_requested);

        const expected = if (fail_error_reply) "+OK\r\n" else "+OK\r\n-ERR something went wrong\r\n";
        try testing.expectEqualStrings(expected, fake_io.written());
        var stored = (try data_store.get("fruit", 0)).?;
        defer stored.deinit();
        try testing.expectEqualStrings("apple", stored.value.string);
        try testing.expectEqual(1, try data_store.dbsize(0));
        const events = test_logger.recordedEvents();
        try testing.expectEqual(@as(usize, if (fail_error_reply) 2 else 1), events.len);
        try testing.expectEqual(error.OutOfMemory, events[0].source.?);
        if (fail_error_reply) try testing.expectEqual(error.NetworkDown, events[1].source.?);
        try testing.expectEqual(0, fake_io.close_calls);
    }
}

test "a growing pipeline tail preserves earlier commands and supports reuse" {
    const testing = std.testing;
    const DefaultStorage = @import("storage/default_storage.zig");
    const PersistenceState = @import("persistence_state.zig");
    const persistence = @import("persistence.zig");
    const large_value = "banana" ** 24;
    const first_request = try std.fmt.allocPrint(testing.allocator, "*1\r\n$4\r\nPING\r\n" ++
        "*3\r\n$3\r\nSET\r\n$5\r\nfruit\r\n$5\r\napple\r\n" ++
        "*2\r\n$3\r\nGET\r\n$5\r\nfruit\r\n" ++
        "*3\r\n$3\r\nSET\r\n$5\r\nfruit\r\n${d}\r\n{s}", .{ large_value.len, large_value[0..17] });
    defer testing.allocator.free(first_request);
    const remainder = try std.fmt.allocPrint(testing.allocator, "{s}\r\n*2\r\n$3\r\nGET\r\n$5\r\nfruit\r\n" ++
        "*3\r\n$3\r\nSET\r\n$5\r\nfruit\r\n$4\r\nplum\r\n" ++
        "*2\r\n$3\r\nGET\r\n$5\r\nfruit\r\n", .{large_value[17..]});
    defer testing.allocator.free(remainder);
    var fake_io: TestConnectionIo = .{ .requests = &.{ first_request, remainder } };
    var test_logger = logging.TestLogger.init();
    var backend = DefaultStorage.init(testing.io, testing.allocator);
    var persistence_state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });
    var kgc = try persistence.KgcPersistence.init(testing.io, testing.allocator, &persistence_state, "connection-retained-tail.kgc");
    var memory_store = store.MemoryStore.init(testing.allocator, &.{backend.storage()}, kgc.snapshot(), null);
    var data_store = memory_store.store();
    defer data_store.deinit();

    serve(fake_io.io(), test_logger.logger(), .{ .socket = .{ .handle = 1, .address = undefined } }, &data_store, testing.allocator, 36, &never_stop_requested);

    const expected = try std.fmt.allocPrint(testing.allocator, "+PONG\r\n+OK\r\n$5\r\napple\r\n+OK\r\n${d}\r\n{s}\r\n+OK\r\n$4\r\nplum\r\n", .{ large_value.len, large_value });
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, fake_io.written());
    var stored = (try data_store.get("fruit", 0)).?;
    defer stored.deinit();
    try testing.expectEqualStrings("plum", stored.value.string);
    try testing.expectEqual(0, test_logger.recordedEvents().len);
    try testing.expectEqual(0, fake_io.close_calls);
}

test "pipelined borrowed and owned replies finish through short writes" {
    const testing = std.testing;
    const DefaultStorage = @import("storage/default_storage.zig");
    const PersistenceState = @import("persistence_state.zig");
    const persistence = @import("persistence.zig");
    var fake_io: TestConnectionIo = .{
        .requests = &.{
            "*2\r\n$4\r\nECHO\r\n$3\r\n\x00\r\n\r\n" ++
                "*2\r\n$4\r\nPING\r\n$3\r\n\x00\r\n\r\n" ++
                "*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$3\r\n\x00\r\n\r\n" ++
                "*2\r\n$3\r\nGET\r\n$3\r\nkey\r\n" ++
                "*4\r\n$3\r\nSET\r\n$3\r\nkey\r\n$4\r\nnext\r\n$3\r\nGET\r\n" ++
                "*2\r\n$3\r\nGET\r\n$3\r\nkey\r\n",
            "*2\r\n$4\r\nECHO\r\n$0\r\n\r\n",
        },
        .max_write_bytes = 2,
    };
    var test_logger = logging.TestLogger.init();
    var backend = DefaultStorage.init(testing.io, testing.allocator);
    var persistence_state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });
    var kgc = try persistence.KgcPersistence.init(testing.io, testing.allocator, &persistence_state, "connection-reply-lifetime.kgc");
    var memory_store = store.MemoryStore.init(testing.allocator, &.{backend.storage()}, kgc.snapshot(), null);
    var data_store = memory_store.store();
    defer data_store.deinit();

    serve(fake_io.io(), test_logger.logger(), .{ .socket = .{ .handle = 1, .address = undefined } }, &data_store, testing.allocator, 48, &never_stop_requested);

    try testing.expectEqualStrings(
        "$3\r\n\x00\r\n\r\n$3\r\n\x00\r\n\r\n+OK\r\n" ++
            "$3\r\n\x00\r\n\r\n$3\r\n\x00\r\n\r\n$4\r\nnext\r\n$0\r\n\r\n",
        fake_io.written(),
    );
    var stored = (try data_store.get("key", 0)).?;
    defer stored.deinit();
    try testing.expectEqualStrings("next", stored.value.string);
    try testing.expectEqual(0, test_logger.recordedEvents().len);
    try testing.expectEqual(0, fake_io.close_calls);
}

test "invalid later DEL elements prevent mutation and stop the connection" {
    const testing = std.testing;
    const invalid_elements = [_][]const u8{ ":42\r\n", "$-1\r\n", "*0\r\n", "+apple\r\n", "-ERR\r\n" };
    for (invalid_elements) |element| {
        var buffer: [128]u8 = undefined;
        const request = try std.fmt.bufPrint(&buffer, "*3\r\n$3\r\nDEL\r\n$5\r\nfruit\r\n{s}*1\r\n$6\r\nDBSIZE\r\n", .{element});
        var fake_io: TestConnectionIo = .{ .requests = &.{ request, "*1\r\n$4\r\nPING\r\n" } };
        var test_logger = logging.TestLogger.init();
        var mock = store.MockStore.init();
        var data_store = mock.store();

        serve(fake_io.io(), test_logger.logger(), .{ .socket = .{ .handle = 1, .address = undefined } }, &data_store, testing.allocator, 1024, &never_stop_requested);

        try testing.expectEqual(0, mock.remove_calls);
        try testing.expectEqual(0, mock.dbsize_calls);
        try testing.expectEqual(1, fake_io.next_request);
        try testing.expect(std.mem.startsWith(u8, fake_io.written(), "-ERR protocol error:"));
        try testing.expectEqual(0, test_logger.recordedEvents().len);
    }
}

test "a partial reply failure stops before the next pipelined command" {
    const testing = std.testing;
    const cases = [_]struct { request: []const u8, expected: []const u8 }{
        .{ .request = "*1\r\n$4\r\nPING\r\n*1\r\n$6\r\nDBSIZE\r\n", .expected = "+PO" },
        .{ .request = "*3\r\n$7\r\nCOMMAND\r\n$4\r\nINFO\r\n$3\r\nGET\r\n*1\r\n$6\r\nDBSIZE\r\n", .expected = "*1\r" },
    };
    for (cases) |case| {
        var fake_io: TestConnectionIo = .{
            .requests = &.{case.request},
            .fail_after_bytes = case.expected.len,
        };
        var test_logger = logging.TestLogger.init();
        var mock = store.MockStore.init();
        var data_store = mock.store();
        serve(fake_io.io(), test_logger.logger(), .{ .socket = .{ .handle = 1, .address = undefined } }, &data_store, testing.allocator, 1024, &never_stop_requested);
        try testing.expectEqualStrings(case.expected, fake_io.written());
        try testing.expectEqual(0, mock.dbsize_calls);
        try testing.expectEqual(1, test_logger.recordedEvents().len);
        try testing.expectEqual(error.NetworkDown, test_logger.recordedEvents()[0].source.?);
    }
}

test "stopping prevents a new command while a live reply finishes" {
    const testing = std.testing;
    const DefaultStorage = @import("storage/default_storage.zig");
    const PersistenceState = @import("persistence_state.zig");
    const persistence = @import("persistence.zig");
    for ([_]enum { read, write }{ .read, .write }) |stop_during| {
        var stop_requested: std.atomic.Value(bool) = .init(false);
        var fake_io: TestConnectionIo = .{
            .requests = &.{"*2\r\n$3\r\nGET\r\n$5\r\nfruit\r\n*3\r\n$3\r\nSET\r\n$5\r\nfruit\r\n$6\r\nbanana\r\n"},
            .max_write_bytes = 2,
            .stop_after_read = if (stop_during == .read) &stop_requested else null,
            .stop_during_write = if (stop_during == .write) &stop_requested else null,
        };
        var test_logger = logging.TestLogger.init();
        var backend = DefaultStorage.init(testing.io, testing.allocator);
        var persistence_state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });
        var kgc = try persistence.KgcPersistence.init(testing.io, testing.allocator, &persistence_state, "connection-stop-between-commands.kgc");
        var memory_store = store.MemoryStore.init(testing.allocator, &.{backend.storage()}, kgc.snapshot(), null);
        var data_store = memory_store.store();
        defer data_store.deinit();
        var initial = try data_store.set(.{ .key = "fruit", .value = "apple", .condition = null, .expires_at = null, .response = null }, 0);
        if (initial.value) |*previous| previous.deinit();

        serve(fake_io.io(), test_logger.logger(), .{ .socket = .{ .handle = 1, .address = undefined } }, &data_store, testing.allocator, 64, &stop_requested);

        try testing.expect(stop_requested.load(.acquire));
        try testing.expectEqualStrings(if (stop_during == .read) "" else "$5\r\napple\r\n", fake_io.written());
        var stored = (try data_store.get("fruit", 0)).?;
        defer stored.deinit();
        try testing.expectEqualStrings("apple", stored.value.string);
        try testing.expectEqual(0, test_logger.recordedEvents().len);
        try testing.expectEqual(0, fake_io.close_calls);
    }
}

test "failed owned replies release their copies and stop later mutations" {
    const testing = std.testing;
    const DefaultStorage = @import("storage/default_storage.zig");
    const PersistenceState = @import("persistence_state.zig");
    const persistence = @import("persistence.zig");
    const cases = [_]struct { request: []const u8, stored_value: []const u8 }{
        .{ .request = "*2\r\n$3\r\nGET\r\n$5\r\nfruit\r\n", .stored_value = "apple" },
        .{ .request = "*4\r\n$3\r\nSET\r\n$5\r\nfruit\r\n$6\r\nbanana\r\n$3\r\nGET\r\n", .stored_value = "banana" },
    };
    for (cases) |case| {
        var request_bytes: [96]u8 = undefined;
        const request = try std.fmt.bufPrint(&request_bytes, "{s}*2\r\n$3\r\nDEL\r\n$5\r\nfruit\r\n", .{case.request});
        var fake_io: TestConnectionIo = .{ .requests = &.{request}, .fail_after_bytes = 6, .max_write_bytes = 2 };
        var test_logger = logging.TestLogger.init();
        var backend = DefaultStorage.init(testing.io, testing.allocator);
        var persistence_state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });
        var kgc = try persistence.KgcPersistence.init(testing.io, testing.allocator, &persistence_state, "connection-failed-owned-replies.kgc");
        var memory_store = store.MemoryStore.init(testing.allocator, &.{backend.storage()}, kgc.snapshot(), null);
        var data_store = memory_store.store();
        defer data_store.deinit();
        var initial = try data_store.set(.{ .key = "fruit", .value = "apple", .condition = null, .expires_at = null, .response = null }, 0);
        if (initial.value) |*previous| previous.deinit();

        serve(fake_io.io(), test_logger.logger(), .{ .socket = .{ .handle = 1, .address = undefined } }, &data_store, testing.allocator, 80, &never_stop_requested);

        try testing.expectEqualStrings("$5\r\nap", fake_io.written());
        var stored = (try data_store.get("fruit", 0)).?;
        defer stored.deinit();
        try testing.expectEqualStrings(case.stored_value, stored.value.string);
        try testing.expectEqual(0, fake_io.close_calls);
        const events = test_logger.recordedEvents();
        try testing.expectEqual(1, events.len);
        try testing.expectEqual(error.NetworkDown, events[0].source.?);
    }
}
