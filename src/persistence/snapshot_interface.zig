const Storage = @import("../storage/interface.zig");
const Store = @import("../store/interface.zig");

const SnapshotPersistence = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const Error = error{SaveAlreadyInProgress};

pub const VTable = struct {
    save: *const fn (*anyopaque, storages: []const Storage) anyerror!void,
    bgsave: *const fn (*anyopaque, storages: []const Storage, origin: Store.TriggerOrigin) anyerror!void,
    load: *const fn (*anyopaque, storages: []const Storage) anyerror!void,
};

pub fn save(self: SnapshotPersistence, storages: []const Storage) anyerror!void {
    return self.vtable.save(self.ptr, storages);
}

pub fn bgsave(self: SnapshotPersistence, storages: []const Storage, origin: Store.TriggerOrigin) anyerror!void {
    return self.vtable.bgsave(self.ptr, storages, origin);
}

pub fn load(self: SnapshotPersistence, storages: []const Storage) anyerror!void {
    return self.vtable.load(self.ptr, storages);
}
