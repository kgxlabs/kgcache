const Storage = @import("../storage/interface.zig");

const SnapshotPersistence = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const Error = error{
    UnableToSave,
};

pub const VTable = struct {
    save: *const fn (*anyopaque, storages: []const Storage) Error!void,
};

pub fn save(self: SnapshotPersistence, storages: []const Storage) Error!void {
    return self.vtable.save(self.ptr, storages);
}
