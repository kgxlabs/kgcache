const std = @import("std");
const object = @import("object.zig");

pub const ObjectExpirationMs = i64;
pub const ObjectExpiration = struct {
    // NOTE: This key is borrowed from the `HashTable/HashMap`. `HashTable/HashMap` owns the key
    // So we don't need to free the key by ourselves.
    // Freeing the keys from the `HashTable/HashMap` is enough
    key: []const u8,
    expiration_ms: ObjectExpirationMs,
};

pub const Object = struct {
    value: object.Object,
    exp_index: ?u32,
};
