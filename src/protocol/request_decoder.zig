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

pub fn decode(input: []const u8, allocator: std.mem.Allocator, limits: Limits) DecodeError!DecodeResult {
    var scanner: Scanner = .{ .input = input, .limits = limits };
    // first phase: checking everything is valid before allocating
    const count = (try scanner.readLength('*')) orelse return .incomplete;

    if (count > limits.max_elements) return error.TooManyElements;

    _ = std.math.mul(usize, count - 1, @sizeOf([]const u8)) catch return error.ArgumentTableTooLarge;

    try scanner.checkFrameSize(scanner.offset, count);

    for (0..count) |index| {
        _ = (try scanner.readBulk(count - index - 1)) orelse return .incomplete;
    }

    const consumed = scanner.offset;

    // count - 1 because we exclude the directive name
    const arguments = try allocator.alloc([]const u8, count - 1);
    errdefer allocator.free(arguments);

    // second phase, actually decoding
    scanner.offset = 0;
    _ = (try scanner.readLength('*')).?;

    const name = (try scanner.readBulk(arguments.len)).?;

    for (arguments, 0..) |*argument, index| {
        argument.* = (try scanner.readBulk(arguments.len - index - 1)).?;
    }

    return .{ .complete = .{
        .frame = .{ .name = name, .arguments = arguments },
        .consumed = consumed,
    } };
}

const Scanner = struct {
    input: []const u8,
    limits: Limits,
    offset: usize = 0,

    fn readLength(self: *Scanner, comptime marker: u8) DecodeError!?usize {
        if (self.offset == self.input.len) return null;

        if (self.input[self.offset] != marker) {
            return if (marker == '*') error.ExpectedArray else error.ExpectedBulkString;
        }

        const invalid_length = if (marker == '*') error.InvalidArrayLength else error.InvalidBulkLength;

        self.offset = std.math.add(usize, self.offset, 1) catch return error.LengthOverflow;

        try self.checkFrameSize(self.offset, 0);

        const start = self.offset;
        var length: usize = 0;

        while (self.offset < self.input.len) {
            const byte = self.input[self.offset];
            switch (byte) {
                '0'...'9' => {
                    length = std.math.mul(usize, length, 10) catch return error.LengthOverflow;
                    length = std.math.add(usize, length, byte - '0') catch return error.LengthOverflow;

                    if (std.math.cast(i64, length) == null) return error.LengthOverflow;

                    self.offset = std.math.add(usize, self.offset, 1) catch return error.LengthOverflow;
                    try self.checkFrameSize(self.offset, 0);
                },
                '\r' => {
                    if (self.offset == start) return invalid_length;

                    const end = std.math.add(usize, self.offset, 2) catch return error.LengthOverflow;

                    if (end <= self.input.len and self.input[end - 1] != '\n') return error.InvalidLineEnding;

                    if (marker == '*' and length == 0) return error.EmptyArray;

                    try self.checkFrameSize(end, 0);

                    if (end > self.input.len) return null;

                    self.offset = end;
                    return length;
                },
                '\n' => return error.InvalidLineEnding,
                else => return invalid_length,
            }
        }
        return null;
    }

    fn readBulk(self: *Scanner, remaining_elements: usize) DecodeError!?[]const u8 {
        const length = (try self.readLength('$')) orelse return null;
        const start = self.offset;
        const body_end = std.math.add(usize, start, length) catch return error.LengthOverflow;
        const end = std.math.add(usize, body_end, 2) catch return error.LengthOverflow;

        try self.checkFrameSize(end, remaining_elements);

        if (body_end >= self.input.len) return null;

        if (self.input[body_end] != '\r') return error.InvalidBulkTerminator;

        if (end > self.input.len) return null;

        if (self.input[end - 1] != '\n') return error.InvalidBulkTerminator;

        self.offset = end;
        return self.input[start..body_end];
    }

    fn checkFrameSize(self: Scanner, end: usize, remaining_elements: usize) DecodeError!void {
        const remaining_bytes = std.math.mul(usize, remaining_elements, "$0\r\n\r\n".len) catch return error.LengthOverflow;
        const minimum_size = std.math.add(usize, end, remaining_bytes) catch return error.LengthOverflow;

        if (minimum_size > self.limits.max_frame_bytes) return error.FrameTooLarge;
    }
};
