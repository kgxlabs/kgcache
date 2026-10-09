const std = @import("std");

pub const Tokens = struct {
    pub const Array: []const u8 = "*";
    pub const BulkString: []const u8 = "$";
    pub const SimpleString: []const u8 = "+";
    pub const SimpleError: []const u8 = "-";
    pub const Integer: []const u8 = ":";
    pub const CR: []const u8 = "\r";
    pub const LF: []const u8 = "\n";
    pub const CRLF: []const u8 = "\r\n";
};

pub const RESPValue = union(enum) {
    array: ?[]RESPValue,
    bulk_string: ?[]const u8,
    simple_string: []const u8,
    integer: i64,
    simple_error: []const u8,
};

pub const ParseError = std.mem.Allocator.Error || error{
    NotInteger,
    Incomplete,
    MalformedSize,
    ExceededSize,
    InvalidType,
    IncorrectToken,
    Malformed,
};
const RESPError = ParseError;

fn ParseResult(comptime T: type) type {
    return struct {
        value: T,
        consumed: usize,
    };
}

// TODO: Refactor this with tagged unions instead of switch statement
pub const Parser = struct {
    _pos: usize = 0,
    data: []const u8,

    const Self = @This();

    pub fn parse(self: *Self, allocator: std.mem.Allocator) RESPError!RESPValue {
        const result = try parseRESP(allocator, self.data);
        self._pos += result.consumed - 1;

        return result.value;
    }

    pub fn next(self: *Self, allocator: std.mem.Allocator) RESPError!?RESPValue {
        if (self._pos >= self.data.len) return null;
        const result = try parseRESP(allocator, self.data[self._pos..]);
        self._pos += result.consumed;
        return result.value;
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator, value: RESPValue) void {
        _ = self;
        deinitValue(allocator, value);
    }
};

fn deinitValue(allocator: std.mem.Allocator, value: RESPValue) void {
    switch (value) {
        .array => |optional_items| {
            if (optional_items) |items| {
                for (items) |item| {
                    deinitValue(allocator, item);
                }
                allocator.free(items);
            }
        },
        else => {},
    }
}

pub fn parser(data: []const u8) Parser {
    return .{ .data = data };
}

fn parseRESP(allocator: std.mem.Allocator, data: []const u8) RESPError!ParseResult(RESPValue) {
    if (data.len == 0) {
        return RESPError.Malformed;
    }

    const result = switch (data[0]) {
        '*' => try parseArray(allocator, data),
        '$' => try parseBulkstring(data),
        '+' => try parseSimpleString(data),
        ':' => try parseInteger(data),
        '-' => try parseSimpleError(data),
        else => return RESPError.InvalidType,
    };

    return result;
}

fn parseArray(allocator: std.mem.Allocator, data: []const u8) RESPError!ParseResult(RESPValue) {
    var list: std.ArrayList(RESPValue) = .empty;
    errdefer {
        for (list.items) |item| deinitValue(allocator, item);
        list.deinit(allocator);
    }

    var pos: usize = 0;

    const parsed_size = try parseSize(data, Tokens.Array);
    pos += parsed_size.consumed;

    if (parsed_size.value == -1) {
        return .{
            .value = .{ .array = null },
            .consumed = parsed_size.consumed,
        };
    }

    const len: usize = @intCast(parsed_size.value);

    for (0..len) |_| {
        // if there is nothing to be parsed in bytes while size is still iterating, that means wrong no. of arguments
        if (data[pos..].len == 0) {
            return RESPError.Incomplete;
        }

        // Get first byte and match it with supported operators
        const parsed_item = try parseRESP(allocator, data[pos..]);
        list.append(allocator, parsed_item.value) catch |err| {
            deinitValue(allocator, parsed_item.value);
            return err;
        };

        pos += parsed_item.consumed;
    }

    const items = try list.toOwnedSlice(allocator);
    return .{
        .value = .{ .array = items },
        .consumed = pos,
    };
}

fn parseSimpleString(data: []const u8) RESPError!ParseResult(RESPValue) {
    if (!std.mem.eql(u8, data[0..1], Tokens.SimpleString)) {
        return RESPError.IncorrectToken;
    }

    const maybe_end = std.mem.indexOf(u8, data, Tokens.CRLF);
    if (maybe_end == null) {
        return RESPError.Incomplete;
    }

    const end = maybe_end.?;

    return .{
        .value = .{
            .simple_string = data[1..end],
        },
        .consumed = end + 2,
    };
}

fn parseInteger(data: []const u8) RESPError!ParseResult(RESPValue) {
    if (!std.mem.eql(u8, data[0..1], Tokens.Integer)) {
        return RESPError.IncorrectToken;
    }

    const maybe_end = std.mem.indexOf(u8, data, Tokens.CRLF);
    if (maybe_end == null) {
        return RESPError.Incomplete;
    }

    const end = maybe_end.?;

    const num = std.fmt.parseInt(i64, data[1..end], 10) catch {
        return RESPError.NotInteger;
    };

    return .{
        .value = .{
            .integer = num,
        },
        .consumed = end + 2,
    };
}

fn parseSimpleError(data: []const u8) RESPError!ParseResult(RESPValue) {
    if (!std.mem.eql(u8, data[0..1], Tokens.SimpleError)) {
        return RESPError.IncorrectToken;
    }

    const maybe_end = std.mem.indexOf(u8, data, Tokens.CRLF);
    if (maybe_end == null) {
        return RESPError.Incomplete;
    }

    const end = maybe_end.?;

    return .{
        .value = .{
            .simple_error = data[1..end],
        },
        .consumed = end + 2,
    };
}

fn parseBulkstring(data: []const u8) RESPError!ParseResult(RESPValue) {
    var pos: usize = 0;
    const parsed_size = try parseSize(data, Tokens.BulkString);
    pos += parsed_size.consumed;

    if (parsed_size.value == -1) {
        return .{
            .value = .{
                .bulk_string = null,
            },
            .consumed = parsed_size.consumed,
        };
    }

    const len: usize = @intCast(parsed_size.value);
    const body_end = std.math.add(usize, pos, len) catch return RESPError.MalformedSize;
    const end = std.math.add(usize, body_end, 2) catch return RESPError.MalformedSize;
    if (data.len <= body_end) return RESPError.Incomplete;
    if (data[body_end] != '\r') return RESPError.Malformed;
    if (data.len < end) return RESPError.Incomplete;
    if (data[body_end + 1] != '\n') return RESPError.Malformed;
    const str = data[pos..body_end];
    pos = end;

    return .{
        .value = .{
            .bulk_string = str,
        },
        .consumed = pos,
    };
}

fn parseSize(data: []const u8, token: []const u8) RESPError!ParseResult(isize) {
    var pos: usize = 0;
    if (!isToken(data[pos .. pos + 1], token)) return RESPError.IncorrectToken;

    const end = std.mem.indexOf(u8, data, Tokens.CRLF);
    if (end == null) {
        return RESPError.Incomplete;
    }

    // NOTE: We are doing pos+1 because we want to skip the token `$` or `*`
    const len = std.fmt.parseInt(isize, data[pos + 1 .. end.?], 10) catch return RESPError.MalformedSize;

    pos += end.? + 2;

    if (len < -1) return RESPError.MalformedSize;

    return .{
        .value = len,
        .consumed = pos,
    };
}

pub const Serializer = struct {
    pub fn serialize(_: Serializer, allocator: std.mem.Allocator, value: RESPValue) std.mem.Allocator.Error![]const u8 {
        return switch (value) {
            .bulk_string => |bs_value| return serializeBulkString(allocator, bs_value),
            .simple_string => |str_value| return serializeSimpleString(allocator, str_value),
            .integer => |int_value| return serializeInteger(allocator, int_value),
            .array => |arr_value| return serializeArray(allocator, arr_value),
            .simple_error => |err_value| return serializeErrorString(allocator, err_value),
        };
    }

    pub fn deinit(_: Serializer, allocator: std.mem.Allocator, value: []const u8) void {
        allocator.free(value);
    }
};

pub fn serializer() Serializer {
    return Serializer{};
}

fn serializeBulkString(allocator: std.mem.Allocator, maybe_value: ?[]const u8) std.mem.Allocator.Error![]const u8 {
    if (maybe_value == null) {
        // TODO: Here we can simply use string literal but then the client code needs to know if the result is stack memory or heap memory.
        // This makes sure that we dont free urelated memory but this does heap allocator which is not ideal
        // Improve this if better approach is found
        return std.fmt.allocPrint(allocator, "$-1\r\n", .{});
    }

    const value = maybe_value.?;
    return std.fmt.allocPrint(allocator, "${d}\r\n{s}\r\n", .{ value.len, value });
}

fn serializeSimpleString(allocator: std.mem.Allocator, value: []const u8) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "+{s}\r\n", .{value});
}

fn serializeInteger(allocator: std.mem.Allocator, value: i64) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, ":{d}\r\n", .{value});
}

fn serializeErrorString(allocator: std.mem.Allocator, err_msg: []const u8) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "-{s}\r\n", .{err_msg});
}

fn serializeArray(allocator: std.mem.Allocator, maybe_value: ?[]RESPValue) std.mem.Allocator.Error![]const u8 {
    if (maybe_value == null) {
        return std.fmt.allocPrint(allocator, "*-1\r\n", .{});
    }

    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);

    const values = maybe_value.?;
    const header = try std.fmt.allocPrint(allocator, "*{d}\r\n", .{values.len});
    defer allocator.free(header);
    try list.appendSlice(allocator, header);
    for (values) |item| {
        const serialized_value = try switch (item) {
            .bulk_string => |bs| serializeBulkString(allocator, bs),
            .simple_string => |str_value| serializeSimpleString(allocator, str_value),
            .integer => |int_value| serializeInteger(allocator, int_value),
            .array => |arr_value| serializeArray(allocator, arr_value),
            .simple_error => |err_value| serializeErrorString(allocator, err_value),
        };
        defer allocator.free(serialized_value);

        try list.appendSlice(allocator, serialized_value);
    }

    return list.toOwnedSlice(allocator);
}

fn isToken(data: []const u8, token: []const u8) bool {
    return std.mem.eql(u8, data, token);
}
