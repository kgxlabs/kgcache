const std = @import("std");
const resp = @import("resp.zig");

pub const Object = union(enum) {
    string: []const u8,
    // TODO: Add more types --- list, set, sorted set, hash, stream
};

// TODO: Currently only handles string. handle more types in future
pub fn fromRESP(value: resp.RESPValue) !Object {
    return switch (value) {
        .bulk_string => |maybe_str| return stringFromRESP(maybe_str),
        else => return error.InvalidType,
    };
}

fn stringFromRESP(maybe_str: ?[]const u8) !Object {
    const value = maybe_str orelse "";
    return .{ .string = value };
}

pub fn toRESP(value: Object) !resp.RESPValue {
    return switch (value) {
        .string => |str| return stringToRESP(str),
    };
}

fn stringToRESP(value: []const u8) !resp.RESPValue {
    return .{ .bulk_string = value };
}
