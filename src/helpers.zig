const std = @import("std");

pub fn eqlStringIgnoreCase(value: []const u8, expected: []const u8) bool {
    return std.ascii.eqlIgnoreCase(value, expected);
}

pub fn isEpochS(value: i64) bool {
    // Unix seconds between 2000 and 2100
    return value >= 946684800 and value <= 4102444800;
}

pub fn isEpochMs(value: i64) bool {
    // Unix milli seconds between 2000 and 2100
    return value >= 946684800000 and value <= 4102444800000;
}
