const std = @import("std");
const Lock = @import("../lock.zig");
const protocol = @import("../protocol.zig");

const ConnectionReport = @This();

pub const Values = struct {
    last_activity: std.Io.Timestamp,
    db_index: u32 = 0,
    resp: protocol.Resp.Version = .resp2,
    last_command: []const u8 = "NULL",
    lib_name: []const u8 = "",
    lib_ver: []const u8 = "",
    total_net_in: u64 = 0,
    total_net_out: u64 = 0,
    total_cmds: u64 = 0,
};

pub const Snapshot = struct {
    values: Values,
    _allocator: std.mem.Allocator,

    pub fn deinit(self: *Snapshot) void {
        self._allocator.free(self.values.last_command);
        self._allocator.free(self.values.lib_name);
        self._allocator.free(self.values.lib_ver);
        self.* = undefined;
    }
};

_lock: Lock,
_values: Values,

pub fn init(io: std.Io, registered_at: std.Io.Timestamp) ConnectionReport {
    return .{ ._lock = Lock.init(io), ._values = .{ .last_activity = registered_at } };
}

pub fn snapshot(self: *ConnectionReport, allocator: std.mem.Allocator) std.mem.Allocator.Error!Snapshot {
    var tx = self._lock.beginUncancelable();
    defer tx.end();

    var values = self._values;
    values.last_command = try allocator.dupe(u8, values.last_command);
    errdefer allocator.free(values.last_command);

    values.lib_name = try allocator.dupe(u8, values.lib_name);
    errdefer allocator.free(values.lib_name);

    values.lib_ver = try allocator.dupe(u8, values.lib_ver);

    return .{ .values = values, ._allocator = allocator };
}

pub fn recordRead(self: *ConnectionReport, byte_count: u64, at: std.Io.Timestamp) void {
    if (byte_count == 0) return;

    var tx = self._lock.beginUncancelable();
    defer tx.end();

    // caps at max(u64)
    self._values.total_net_in +|= byte_count;
    self.recordActivity(at);
}

pub fn recordWrite(self: *ConnectionReport, byte_count: u64, at: std.Io.Timestamp) void {
    if (byte_count == 0) return;

    var tx = self._lock.beginUncancelable();
    defer tx.end();

    // caps at max(u64)
    self._values.total_net_out +|= byte_count;
    self.recordActivity(at);
}

pub fn recordDispatch(self: *ConnectionReport, canonical_name: []const u8) void {
    var tx = self._lock.beginUncancelable();
    defer tx.end();

    // caps at max(u64)
    self._values.total_cmds +|= 1;
    self._values.last_command = canonical_name;
}

pub fn recordDbAndProto(self: *ConnectionReport, db_index: u32, resp: protocol.Resp.Version) void {
    var tx = self._lock.beginUncancelable();
    defer tx.end();

    self._values.db_index = db_index;
    self._values.resp = resp;
}

fn recordActivity(self: *ConnectionReport, at: std.Io.Timestamp) void {
    if (at.nanoseconds > self._values.last_activity.nanoseconds) self._values.last_activity = at;
}
