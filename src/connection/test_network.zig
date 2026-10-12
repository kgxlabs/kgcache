const std = @import("std");
const ConnectionContext = @import("context.zig");
const protocol = @import("../protocol.zig");
const ConnectionReport = @import("report.zig");
const TestNetwork = @This();

base_io: std.Io,
expected_blocked_reads: usize,
immediate_eof_handle: ?std.Io.net.Socket.Handle = null,
local_endpoint_error: ?anyerror = null,
local_endpoint_value: std.Io.net.IpAddress = .{ .ip4 = .loopback(6379) },
local_endpoint_calls: usize = 0,
last_local_endpoint_handle: ?std.Io.net.Socket.Handle = null,
registration_time: ?std.Io.Timestamp = null,
awake_samples: std.atomic.Value(usize) = .init(0),
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
    self.vtable.now = now;
    return .{ .userdata = self, .vtable = &self.vtable };
}

pub fn stream(handle: usize) std.Io.net.Stream {
    return .{ .socket = .{ .handle = @intCast(handle), .address = .{ .ip4 = .loopback(@intCast(10000 + handle)) } } };
}

pub fn identityContext(id: u64) ConnectionContext {
    const Provider = struct {
        var marker: u8 = 0;
        const context_vtable: ConnectionContext.VTable = .{
            .snapshot_current = snapshotCurrent,
            .record_read = recordTransfer,
            .record_write = recordTransfer,
            .record_dispatch = recordDispatch,
            .record_db_and_proto = recordDbAndProto,
            .set_library_info = setLibraryInfo,
        };

        fn snapshotCurrent(_: *anyopaque, _: std.Io, _: std.mem.Allocator) ConnectionContext.Error!ConnectionContext.Snapshot {
            unreachable;
        }

        fn recordTransfer(_: *anyopaque, _: u64, _: std.Io.Timestamp) void {}
        fn recordDispatch(_: *anyopaque, _: []const u8) void {}
        fn recordDbAndProto(_: *anyopaque, _: u32, _: protocol.Resp.Version) void {}
        fn setLibraryInfo(_: *anyopaque, _: ConnectionReport.LibraryAttribute, _: []const u8) ConnectionContext.Error!void {
            unreachable;
        }
    };

    return .{ .id = id, .ptr = &Provider.marker, .vtable = &Provider.context_vtable };
}

pub fn localEndpoint(io_backend: std.Io, handle: std.Io.net.Socket.Handle) anyerror!std.Io.net.IpAddress {
    const self: *TestNetwork = @ptrCast(@alignCast(io_backend.userdata));
    self.local_endpoint_calls += 1;
    self.last_local_endpoint_handle = handle;
    if (self.local_endpoint_error) |err| return err;
    return self.local_endpoint_value;
}

fn now(userdata: ?*anyopaque, clock: std.Io.Clock) std.Io.Timestamp {
    const self: *TestNetwork = @ptrCast(@alignCast(userdata));
    if (clock == .awake) {
        _ = self.awake_samples.fetchAdd(1, .acq_rel);
        if (self.registration_time) |at| return at;
    }
    return self.base_io.vtable.now(self.base_io.userdata, clock);
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
