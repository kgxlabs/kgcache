//! Accepted value counts, **excluding the command or directive name**.

const std = @import("std");

const Arity = @This();

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

pub fn accepts(self: Arity, value_count: usize) bool {
    if (value_count < self.minimum) return false;
    if (self.maximum) |maximum| {
        if (value_count > maximum) return false;
    }
    return true;
}

test "exact arity counts values and supports counts above two" {
    const testing = std.testing;

    const three = Arity.exact(3);
    try testing.expect(!three.accepts(0));
    try testing.expect(!three.accepts(2));
    try testing.expect(three.accepts(3));
    try testing.expect(!three.accepts(4));

    const zero = Arity.exact(0);
    try testing.expect(zero.accepts(0));
    try testing.expect(!zero.accepts(1));
}

test "bounded arity accepts both endpoints and rejects values outside the range" {
    const testing = std.testing;

    const bounded = Arity.range(2, 5);
    try testing.expect(!bounded.accepts(1));
    for (2..6) |count| try testing.expect(bounded.accepts(count));
    try testing.expect(!bounded.accepts(6));

    const single = Arity.range(3, 3);
    try testing.expect(!single.accepts(2));
    try testing.expect(single.accepts(3));
    try testing.expect(!single.accepts(4));
}

test "unbounded arity accepts counts through the usize maximum" {
    const testing = std.testing;

    const unbounded = Arity.atLeast(3);
    try testing.expect(!unbounded.accepts(0));
    try testing.expect(!unbounded.accepts(2));
    try testing.expect(unbounded.accepts(3));
    try testing.expect(unbounded.accepts(4));
    try testing.expect(unbounded.accepts(std.math.maxInt(usize)));

    const any = Arity.atLeast(0);
    try testing.expect(any.accepts(0));
    try testing.expect(any.accepts(std.math.maxInt(usize)));
}
