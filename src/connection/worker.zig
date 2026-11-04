const std = @import("std");
const ClientSession = @import("session.zig");
const ClientRegistry = @import("client_registry.zig");

const ClientWorker = @This();

client_registy: *ClientRegistry,
stream: std.Io.net.Stream,
client_sessions: std.ArrayList(ClientSession) = .empty,
thread: ?std.Thread = null,
lifecycle: Lifecycle = .starting,

pub const Lifecycle = enum {
    starting,
    running,
    stopping,
    finished,
};

pub fn connectionContext(self: *ClientWorker, id: u64) ConnectionContext {
    return .{ .id = id, .ptr = self, .vtable = &context_vtable };
}

pub fn registerNewConnection(self: *ClientWorker, id: u64) !ConnectionContext {
    return .{ .id = id, .ptr = self, .vtable = &context_vtable };
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
    const self: *ClientWorker = @ptrCast(@alignCast(ptr));
    self.report.recordRead(byte_count, at);
}

fn recordWrite(ptr: *anyopaque, byte_count: u64, at: std.Io.Timestamp) void {
    const self: *ClientWorker = @ptrCast(@alignCast(ptr));
    self.report.recordWrite(byte_count, at);
}

fn recordDispatch(ptr: *anyopaque, canonical_name: []const u8) void {
    const self: *ClientWorker = @ptrCast(@alignCast(ptr));
    self.report.recordDispatch(canonical_name);
}

fn recordDbAndProto(ptr: *anyopaque, db_index: u32, resp: protocol.Resp.Version) void {
    const self: *ClientWorker = @ptrCast(@alignCast(ptr));
    self.report.recordDbAndProto(db_index, resp);
}

fn setLibraryInfo(ptr: *anyopaque, attribute: ConnectionReport.LibraryAttribute, value: []const u8) ConnectionContext.Error!void {
    const self: *ClientWorker = @ptrCast(@alignCast(ptr));
    return self.report.setLibraryInfo(attribute, value);
}

fn snapshotCurrent(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator) ConnectionContext.Error!ConnectionContext.Snapshot {
    const self: *ClientWorker = @ptrCast(@alignCast(ptr));
    const sampled_at = std.Io.Clock.awake.now(io);

    return .{
        .id = self.context.id,
        .peer_endpoint = self.peer_endpoint,
        .local_endpoint = self.local_endpoint,
        .descriptor = self.descriptor,
        .registered_at = self.registered_at,
        .sampled_at = sampled_at,
        .report = try self.report.snapshot(allocator),
    };
}

fn snapshotLive(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator) ConnectionContext.Error!ConnectionContext.LiveSnapshots {
    const self: *ClientWorker = @ptrCast(@alignCast(ptr));
    return self.client_registy.snapshotLive(io, allocator);
}
