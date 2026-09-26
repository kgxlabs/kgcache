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
    output: [512]u8 = undefined,
    output_len: usize = 0,
    close_calls: usize = 0,
    fail_write: bool = false,
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
        self.next_request += 1;
        std.debug.assert(request.len <= data[0].len);
        @memcpy(data[0][0..request.len], request);
        return request.len;
    }

    fn write(ptr: ?*anyopaque, _: std.Io.net.Socket.Handle, header: []const u8, data: []const []const u8, splat: usize) std.Io.net.Stream.Writer.Error!usize {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (self.fail_write) return error.NetworkDown;
        var count: usize = 0;
        self.append(header);
        count += header.len;
        for (data[0 .. data.len - 1]) |part| {
            self.append(part);
            count += part.len;
        }
        if (splat > 0) {
            const part = data[data.len - 1];
            for (0..splat) |_| {
                self.append(part);
                count += part.len;
            }
        }
        return count;
    }

    fn append(self: *@This(), bytes: []const u8) void {
        std.debug.assert(self.output_len + bytes.len <= self.output.len);
        @memcpy(self.output[self.output_len..][0..bytes.len], bytes);
        self.output_len += bytes.len;
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
    var fake_io: TestConnectionIo = .{ .requests = &.{"*1\r\n$6\r\nDBSIZE\r\n"} };
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

test "argument count errors keep their wire responses and allow another request" {
    const testing = std.testing;
    var fake_io: TestConnectionIo = .{ .requests = &.{
        "*2\r\n$6\r\nDBSIZE\r\n$1\r\nx\r\n",
        "*1\r\n$3\r\nGET\r\n",
        "*1\r\n$4\r\nPING\r\n",
    } };
    var test_logger = logging.TestLogger.init();
    var mock = store.MockStore.init();
    var data_store = mock.store();

    serve(fake_io.io(), test_logger.logger(), .{ .socket = .{ .handle = 1, .address = undefined } }, &data_store, testing.allocator, 1024, &never_stop_requested);

    try testing.expectEqualStrings(
        "-Wrong number of arguments\r\n-ERR wrong number of arguments\r\n+PONG\r\n",
        fake_io.written(),
    );
    try testing.expectEqual(3, fake_io.next_request);
    try testing.expectEqual(0, test_logger.recordedEvents().len);
    try testing.expectEqual(0, fake_io.close_calls);
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
