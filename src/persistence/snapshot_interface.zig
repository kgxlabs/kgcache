const object = @import("../object.zig");
const time = @import("../time.zig");

const SnapshotPersistence = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const Error = error{};

pub const VTable = struct {
    beginDump: *const fn (*anyopaque) Error!void,
    dumpEntry: *const fn (*anyopaque, key: []const u8, value: object.Object, exp: ?time.UnixMs) Error!void,
    endDump: *const fn (*anyopaque) Error!void,
};

pub fn beginDump(self: SnapshotPersistence) Error!void {
    return self.vtable.beginDump(self.ptr);
}

pub fn dumpEntry(self: SnapshotPersistence, key: []const u8, value: object.Object, exp: ?time.UnixMs) Error!void {
    return self.vtable.dumpEntry(self.ptr, key, value, exp);
}

pub fn endDump(self: SnapshotPersistence) Error!void {
    return self.vtable.endDump(self.ptr);
}
