const std = @import("std");
const resp = @import("../resp.zig");
const Commander = @import("interface.zig");

pub const Arity = @import("../arity.zig");

/// Encode command arity for Redis metadata, including the command name.
pub fn redisArity(arity: Arity) i64 {
    const minimum_with_name: i64 = @intCast(arity.minimum + 1);
    if (arity.maximum) |maximum| {
        if (maximum == arity.minimum) return minimum_with_name;
    }
    return -minimum_with_name;
}

pub const KeySpec = union(enum) {
    none,
    range: struct {
        first: usize,
        last: union(enum) {
            index: usize,
            remaining,
        },
        step: usize,
        flags: []const KeyFlag,
    },
};

pub const KeyFlag = enum {
    RO,
    RW,
    OW,
    RM,
    access,
    update,
    delete,
    variable_flags,
};

pub const Flag = enum {
    admin,
    fast,
    readonly,
    write,
};

pub const Category = enum {
    admin,
    connection,
    dangerous,
    fast,
    keyspace,
    read,
    slow,
    string,
    write,
};

pub const Factory = *const fn (
    allocator: std.mem.Allocator,
    arguments: []resp.RESPValue,
) Commander.Error!Commander;

pub const Definition = struct {
    name: []const u8,
    arity: Arity,
    flags: []const Flag,
    categories: []const Category,
    keys: KeySpec,
    factory: Factory,
};
