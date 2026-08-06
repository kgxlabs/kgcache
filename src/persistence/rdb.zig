const std = @import("std");
const Snapshot = @import("./snapshot_interface.zig");
const Storage = @import("../storage/interface.zig");
const object = @import("../object.zig");
const time = @import("../time.zig");

const RdbBackend = @This();

const vtable: Snapshot.VTable = .{
    .save = save,
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

pub fn save(ptr: *anyopaque, storage: Storage) Snapshot.Error!void {
    const self: *RdbBackend = @ptrCast(@alignCast(ptr));

    try self.beginDump();
    storage.forEach(self, visitEntry) catch return Snapshot.Error.UnableToSave;
    try self.endDump();
}

fn visitEntry(ctx: *anyopaque, key: []const u8, value: object.Object, exp: ?time.UnixMs) anyerror!void {
    const self: *RdbBackend = @ptrCast(@alignCast(ctx));
    try self.dumpEntry(key, value, exp);
}

fn beginDump(_: *RdbBackend) Snapshot.Error!void {
    return;
}

fn dumpEntry(_: *RdbBackend, _: []const u8, _: object.Object, _: ?time.UnixMs) Snapshot.Error!void {
    return;
}

fn endDump(_: *RdbBackend) Snapshot.Error!void {
    return;
}
