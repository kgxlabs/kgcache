const std = @import("std");
const resp = @import("../resp.zig");
const Commander = @import("interface.zig");

pub const Arity = struct {
    minimum: usize,
    maximum: ?usize,

    pub fn exact(count: usize) Arity {
        return .{
            .minimum = count,
            .maximum = count,
        };
    }

    pub fn range(minimum: usize, maximum: usize) Arity {
        std.debug.assert(minimum <= maximum);
        return .{
            .minimum = minimum,
            .maximum = maximum,
        };
    }

    pub fn atLeast(minimum: usize) Arity {
        return .{
            .minimum = minimum,
            .maximum = null,
        };
    }

    pub fn accepts(self: Arity, argument_count: usize) bool {
        if (argument_count < self.minimum) return false;
        if (self.maximum) |maximum| {
            if (argument_count > maximum) return false;
        }
        return true;
    }

    pub fn redisValue(self: Arity) i64 {
        const minimum_with_name: i64 = @intCast(self.minimum + 1);
        if (self.maximum) |maximum| {
            if (maximum == self.minimum) return minimum_with_name;
        }
        return -minimum_with_name;
    }
};

pub const KeySpec = union(enum) {
    none,
    range: struct {
        first: usize,
        last: union(enum) {
            index: usize,
            remaining,
        },
        step: usize,
    },
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
