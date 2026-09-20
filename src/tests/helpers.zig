// TODO: Refactor: This file could become a dumping ground
// research what is the idiomatic Zig way of doing this type of stuff
const std = @import("std");
const commander = @import("../commander.zig");
const resp = @import("../resp.zig");
const store = @import("../store.zig");
const ClientState = @import("../client_state.zig");
const DefaultStorage = @import("../storage/default_storage.zig");
const persistence = @import("../persistence.zig");
const PersistenceState = @import("../persistence_state.zig");

pub fn executeWithMemoryStore(command: commander.Commander) anyerror!resp.RESPValue {
    const testing = std.testing;
    defer command.deinit();

    var default_storage = DefaultStorage.init(testing.io, testing.allocator);
    // The literal path has the required extension, so init cannot fail.
    var persistence_state = PersistenceState.init(testing.io, .{ .mutual_exclusive = false });
    var kgc_backend = persistence.KgcPersistence.init(testing.io, testing.allocator, &persistence_state, "test.kgc") catch unreachable;
    var memory_store = store.MemoryStore.init(testing.allocator, &.{default_storage.storage()}, kgc_backend.snapshot(), null);
    var data_store = memory_store.store();
    defer data_store.deinit();
    var client_state: ClientState = .{};

    return command.execute(testing.io, &data_store, &client_state);
}

pub fn initCommand(allocator: std.mem.Allocator, value: resp.RESPValue) commander.Error!commander.Commander {
    return commander.init(allocator, value);
}

pub const TestNetwork = struct {
    base_io: std.Io,
    expected_blocked_reads: usize,
    immediate_eof_handle: ?std.Io.net.Socket.Handle = null,
    blocked_reads: std.atomic.Value(usize) = .init(0),
    shutdown_calls: std.atomic.Value(usize) = .init(0),
    close_calls: std.atomic.Value(usize) = .init(0),
    close_before_all_shutdown: std.atomic.Value(bool) = .init(false),
    all_reads_started: std.Io.Event = .unset,
    release_reads: std.Io.Event = .unset,
    immediate_closed: std.Io.Event = .unset,
    vtable: std.Io.VTable = undefined,

    pub fn init(base_io: std.Io, expected_blocked_reads: usize) TestNetwork {
        return .{
            .base_io = base_io,
            .expected_blocked_reads = expected_blocked_reads,
        };
    }

    pub fn io(self: *TestNetwork) std.Io {
        self.vtable = self.base_io.vtable.*;
        self.vtable.futexWait = futexWait;
        self.vtable.futexWaitUncancelable = futexWaitUncancelable;
        self.vtable.futexWake = futexWake;
        self.vtable.netRead = netRead;
        self.vtable.netClose = netClose;
        self.vtable.netShutdown = netShutdown;
        return .{ .userdata = self, .vtable = &self.vtable };
    }

    pub fn stream(handle: usize) std.Io.net.Stream {
        return .{ .socket = .{ .handle = @intCast(handle), .address = undefined } };
    }

    fn futexWait(
        userdata: ?*anyopaque,
        ptr: *const u32,
        expected: u32,
        timeout: std.Io.Timeout,
    ) std.Io.Cancelable!void {
        const self: *TestNetwork = @ptrCast(@alignCast(userdata));
        return self.base_io.vtable.futexWait(self.base_io.userdata, ptr, expected, timeout);
    }

    fn futexWaitUncancelable(userdata: ?*anyopaque, ptr: *const u32, expected: u32) void {
        const self: *TestNetwork = @ptrCast(@alignCast(userdata));
        self.base_io.vtable.futexWaitUncancelable(self.base_io.userdata, ptr, expected);
    }

    fn futexWake(userdata: ?*anyopaque, ptr: *const u32, max_waiters: u32) void {
        const self: *TestNetwork = @ptrCast(@alignCast(userdata));
        self.base_io.vtable.futexWake(self.base_io.userdata, ptr, max_waiters);
    }

    fn netRead(
        userdata: ?*anyopaque,
        handle: std.Io.net.Socket.Handle,
        _: [][]u8,
    ) std.Io.net.Stream.Reader.Error!usize {
        const self: *TestNetwork = @ptrCast(@alignCast(userdata));
        if (self.immediate_eof_handle == handle) return 0;

        const read_count = self.blocked_reads.fetchAdd(1, .acq_rel) + 1;
        if (read_count == self.expected_blocked_reads) {
            self.all_reads_started.set(self.base_io);
        }
        self.release_reads.waitUncancelable(self.base_io);
        return 0;
    }

    fn netShutdown(
        userdata: ?*anyopaque,
        _: std.Io.net.Socket.Handle,
        _: std.Io.net.ShutdownHow,
    ) std.Io.net.ShutdownError!void {
        const self: *TestNetwork = @ptrCast(@alignCast(userdata));
        const shutdown_count = self.shutdown_calls.fetchAdd(1, .acq_rel) + 1;
        if (shutdown_count == self.expected_blocked_reads) {
            self.release_reads.set(self.base_io);
        }
    }

    fn netClose(userdata: ?*anyopaque, handles: []const std.Io.net.Socket.Handle) void {
        const self: *TestNetwork = @ptrCast(@alignCast(userdata));
        for (handles) |handle| {
            if (self.immediate_eof_handle != handle and
                self.shutdown_calls.load(.acquire) < self.expected_blocked_reads)
            {
                self.close_before_all_shutdown.store(true, .release);
            }
            _ = self.close_calls.fetchAdd(1, .acq_rel);
            if (self.immediate_eof_handle == handle) {
                self.immediate_closed.set(self.base_io);
            }
        }
    }
};
