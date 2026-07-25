const std = @import("std");
const object = @import("object.zig");

pub const ObjectExpirationMs = i64;
pub const ObjectExpiration = struct {
    key: []const u8,
    expiration_ms: ObjectExpirationMs,
};

pub const Object = struct {
    value: object.Object,
    exp_index: ?u32,
};
