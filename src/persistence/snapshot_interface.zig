const Storage = @import("../storage/interface.zig");
const Store = @import("../store/interface.zig");

const SnapshotPersistence = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const Error = error{
    UnableToSave,
    UnableToLoad,
    SaveAlreadyInProgress,
};

pub const VTable = struct {
    save: *const fn (*anyopaque, storages: []const Storage) Error!void,
    bgsave: *const fn (*anyopaque, storages: []const Storage, snapshot_change_count: u64, origin: Store.TriggerOrigin) Error!void,
    load: *const fn (*anyopaque, storages: []const Storage) Error!void,
};

pub fn save(self: SnapshotPersistence, storages: []const Storage) Error!void {
    return self.vtable.save(self.ptr, storages);
}

pub fn bgsave(self: SnapshotPersistence, storages: []const Storage, snapshot_change_count: u64, origin: Store.TriggerOrigin) Error!void {
    return self.vtable.bgsave(self.ptr, storages, snapshot_change_count, origin);
}

pub fn load(self: SnapshotPersistence, storages: []const Storage) Error!void {
    return self.vtable.load(self.ptr, storages);
}
