const Storage = @import("interface.zig");
const entry = @import("../entry.zig");
const object = @import("../object.zig");

const vtable: Storage.VTable = .{.get};

pub fn get(ptr: *anyopaque, key: []const u8) Storage.Error!?entry.Object {
    return null;
}

pub fn put(ptr: *anyopaque, key: []const u8, value: object.Object, exp_ms: entry.ObjectExpirationMs) Storage.Error!entry.Object {
    return entry.Object{
        .value = .{ .string = "Testing" },
        .exp_index = null,
    };
}

pub fn remove(ptr: *anyopaque, key: []const u8) Storage.Error!void {
    return;
}

pub fn getExp(ptr: *anyopaque, key: []const u8) Storage.Error!?entry.ObjectExpiration {
    return null;
}

pub fn setExp(ptr: *anyopaque, key: []const u8, exp_ms: ?entry.ObjectExpirationMs) Storage.Error!entry.ObjectExpiration {
    return entry.ObjectExpiration{
        .key = "foo",
        .expiration_ms = 1785000509089,
    };
}

pub fn clearExp(ptr: *anyopaque, key: []const u8) Storage.Error!entry.ObjectExpiration {
    return;
}
