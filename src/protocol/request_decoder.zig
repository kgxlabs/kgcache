const std = @import("std");
const CommandFrame = @import("command_frame.zig");

pub const Limits = struct {
    max_frame_bytes: usize,
    max_elements: usize,
};

pub const network_limits: Limits = .{
    .max_frame_bytes = 1024 * 1024,
    .max_elements = 1024,
};

pub const aof_limits: Limits = .{
    .max_frame_bytes = std.math.maxInt(usize),
    .max_elements = std.math.maxInt(usize),
};

pub const ProtocolError = error{
    ExpectedArray,
    EmptyArray,
    InvalidArrayLength,
    ExpectedBulkString,
    InvalidBulkLength,
    InvalidLineEnding,
    InvalidBulkTerminator,
    LengthOverflow,
};

pub const ResourceError = std.mem.Allocator.Error || error{
    FrameTooLarge,
    TooManyElements,
    ArgumentTableTooLarge,
};

pub const DecodeError = ProtocolError || ResourceError;

pub const Complete = struct {
    frame: CommandFrame,
    consumed: usize,

    pub fn deinit(self: *Complete, allocator: std.mem.Allocator) void {
        allocator.free(self.frame.arguments);
        self.* = undefined;
    }
};

pub const DecodeResult = union(enum) {
    complete: Complete,
    incomplete,
};

pub const DecodeFn = *const fn (
    input: []const u8,
    allocator: std.mem.Allocator,
    limits: Limits,
) DecodeError!DecodeResult;
