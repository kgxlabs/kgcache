const std = @import("std");
const object = @import("object.zig");

pub const ObjectExpirationMs = i64;

pub const ObjectEntry = struct {
    value: object.Object,
};
