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

const RESPError = error{
    NotArray,
    NotCRLF,
    NotBulkString,
    NotInteger,
    Incomplete,
    MalformedSize,
    ExceededSize,
    TooLong,
    InvalidType,
    IncorrectToken,
    Malformed,
    UnknownType,
};

fn errorMessage(err: RESPError) []const u8 {
    return switch (err) {
        error.Malformed => "malformed requst",
        error.NotArray => "value is not an array",
        else => "something went wrong",
        error.UnknownType => "ERR unable to serialize unknown type",
    };
}

fn ParseResult(comptime T: type) type {
    return struct {
        value: T,
        consumed: usize,
    };
}

// TODO: Refactor this with tagged unions instead of switch statement
pub const Parser = struct {
    _pos: usize = 0,
    data: []u8,

    const Self = @This();

    pub fn parse(self: *Self, allocator: std.mem.Allocator) RESPError!RESPValue {
        const result = switch (self.data[0]) {
            '*' => try parseArray(allocator, self.data),
            '$' => try parseBulkstring(self.data),
            '+' => try parseSimpleString(self.data),
            ':' => try parseInteger(self.data),
            '-' => try parseSimpleError(self.data),
            else => return RESPError.InvalidType,
        };

        self._pos += result.consumed - 1;

        return result.value;
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator, value: RESPValue) void {
        switch (value) {
            .array => |optional_items| {
                if (optional_items) |items| {
                    for (items) |item| {
                        self.deinit(allocator, item);
                    }
                    allocator.free(items);
                }
            },
            else => {},
        }
    }
};

pub fn parser(data: []u8) Parser {
    return .{ .data = data };
}

fn parseArray(allocator: std.mem.Allocator, data: []u8) RESPError!ParseResult(RESPValue) {
    var list: std.ArrayList(RESPValue) = .empty;
    errdefer list.deinit(allocator);

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

    // TODO: This is hardcoded only for bulk_string. Refactor to support all types
    for (0..len) |_| {
        const parsed_item = try parseBulkstring(data[pos..]);
        list.append(allocator, parsed_item.value) catch return RESPError.TooLong;

        pos += parsed_item.consumed;
    }

    const items = list.toOwnedSlice(allocator) catch return RESPError.TooLong;
    return .{
        .value = .{ .array = items },
        .consumed = pos,
    };
}

fn parseSimpleString(data: []u8) RESPError!ParseResult(RESPValue) {
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

fn parseInteger(data: []u8) RESPError!ParseResult(RESPValue) {
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

fn parseSimpleError(data: []u8) RESPError!ParseResult(RESPValue) {
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
            .simple_string = data[1..end],
        },
        .consumed = end + 2,
    };
}

fn parseBulkstring(data: []u8) RESPError!ParseResult(RESPValue) {
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

    if (len < -1) {
        return RESPError.MalformedSize;
    }

    if (data.len < pos + len + 2) {
        return RESPError.Incomplete;
    }

    const str = data[pos .. pos + len];
    // TODO: This could be redundant since we only took len size but just to be sure
    if (str.len != len) return RESPError.ExceededSize;
    pos += len;

    if (!isToken(data[pos .. pos + 2], Tokens.CRLF)) return RESPError.Incomplete;
    pos += 2;

    return .{
        .value = .{
            .bulk_string = str,
        },
        .consumed = pos,
    };
}

fn parseSize(data: []u8, token: []const u8) RESPError!ParseResult(isize) {
    var pos: usize = 0;
    if (!isToken(data[pos .. pos + 1], token)) return RESPError.IncorrectToken;

    const end = std.mem.indexOf(u8, data, Tokens.CRLF);
    if (end == null) {
        return RESPError.Incomplete;
    }

    // NOTE: We are doing pos+1 because we want to skip the token `$` or `*`
    const len = std.fmt.parseInt(isize, data[pos + 1 .. end.?], 10) catch return RESPError.MalformedSize;

    pos += end.? + 2;

    if (len < -2) return RESPError.MalformedSize;

    return .{
        .value = len,
        .consumed = pos,
    };
}

pub const Serializer = struct {
    pub fn serialize(_: Serializer, allocator: std.mem.Allocator, value: RESPValue) RESPError![]const u8 {
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

fn serializeBulkString(allocator: std.mem.Allocator, maybe_value: ?[]const u8) RESPError![]const u8 {
    if (maybe_value == null) {
        // TODO: Here we can simply use string literal but then the client code needs to know if the result is stack memory or heap memory.
        // This makes sure that we dont free urelated memory but this does heap allocator which is not ideal
        // Improve this if better approach is found
        return std.fmt.allocPrint(allocator, "$-1\r\n", .{}) catch return RESPError.TooLong;
    }

    const value = maybe_value.?;
    return std.fmt.allocPrint(allocator, "${d}\r\n{s}\r\n", .{ value.len, value }) catch RESPError.TooLong;
}

fn serializeSimpleString(allocator: std.mem.Allocator, value: []const u8) RESPError![]const u8 {
    return std.fmt.allocPrint(allocator, "+{s}\r\n", .{value}) catch RESPError.TooLong;
}

fn serializeInteger(allocator: std.mem.Allocator, value: i64) RESPError![]const u8 {
    return std.fmt.allocPrint(allocator, ":{d}\r\n", .{value}) catch RESPError.TooLong;
}

fn serializeErrorString(allocator: std.mem.Allocator, err_msg: []const u8) RESPError![]const u8 {
    return std.fmt.allocPrint(allocator, "-{s}\r\n", .{err_msg}) catch RESPError.TooLong;
}

fn serializeArray(allocator: std.mem.Allocator, maybe_value: ?[]RESPValue) RESPError![]const u8 {
    if (maybe_value == null) {
        return std.fmt.allocPrint(allocator, "*0\r\n", .{}) catch RESPError.TooLong;
    }

    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);

    // TODO: Implement
    const values = maybe_value.?;
    for (values) |item| {
        const serialized_value = try switch (item) {
            .bulk_string => |bs| serializeBulkString(allocator, bs),
            .simple_string => |str_value| serializeSimpleString(allocator, str_value),
            .integer => |int_value| serializeInteger(allocator, int_value),
            .array => |arr_value| serializeArray(allocator, arr_value),
            .simple_error => |err_value| serializeErrorString(allocator, err_value),
        };
        list.appendSlice(allocator, serialized_value) catch return RESPError.TooLong;
    }

    return list.toOwnedSlice(allocator) catch return RESPError.TooLong;
}

fn isToken(data: []u8, token: []const u8) bool {
    return std.mem.eql(u8, data, token);
}

