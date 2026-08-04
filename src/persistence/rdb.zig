const std = @import("std");
const Snapshot = @import("./snapshot_interface.zig");
const object = @import("../object.zig");
const time = @import("../time.zig");

const RdbBackend = @This();

const vtable: Snapshot.VTable = .{
    .beginDump = beginDump,
    .dumpEntry = dumpEntry,
    .endDump = endDump,
};

pub fn init() RdbBackend {
    return .{};
}

pub fn snapshot(self: *RdbBackend) Snapshot {
    return .{
        .ptr = self,
        .vtable = &vtable,
    };
}

pub fn beginDump(_: *anyopaque) Snapshot.Error!void {
    return;
}

pub fn dumpEntry(_: *anyopaque, _: []const u8, _: object.Object, _: ?time.UnixMs) Snapshot.Error!void {
    return;
}

pub fn endDump(_: *anyopaque) Snapshot.Error!void {
    return;
}
