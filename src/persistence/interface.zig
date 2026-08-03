const Storage = @import("../storage/interface.zig");
const object = @import("../object.zig");

const FsPersistence = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const Error = error{};

pub const WriteEvent = union(enum) {
    put: struct { key: []const u8, value: object.Object, options: Storage.PutOptions },
    remove: struct { key: []const u8 },
};

pub const VTable = struct {
    onWrite: *const fn (*anyopaque, WriteEvent) Error!void,
};

pub fn onWrite(self: FsPersistence, event: WriteEvent) Error!void {
    return self.vtable.onWrite(self.ptr, event);
}
