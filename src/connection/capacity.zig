const std = @import("std");

const Capacity = @This();

pub const Sample = struct {};

pub fn init() Capacity {
    return .{};
}

pub fn deinit(self: *Capacity) !void {}

pub fn observe(self: *Capacity, sample: Sample) !void {}

pub fn evaluate(self: *Capacity) !void {}
