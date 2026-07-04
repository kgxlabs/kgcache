const std = @import("std");

pub const Tokens = struct {
    pub const Array: []const u8 = "*";
    pub const BulkString: []const u8 = "$";
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

const ParseError = error{
    NotArray,
    NotCRLF,
    NotBulkString,
    Incomplete,
    MalformedSize,
    ExceededSize,
    TooLong,
    InvalidType,
    IncorrectToken,
    Malformed,
};

// TODO: add all standard error messages
fn parserErrorMessage(err: ParseError) []u8 {
    return switch (err) {
        error.Malformed => "ERR malformed requst",
        error.NotArray => "ERR value is not an array",
        else => "ERR something went wrong",
    };
}

const SerializeError = error{UnknownType};

fn serializerErrorMessage(err: SerializeError) []u8 {
    return switch (err) {
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

    pub fn parse(self: *Self, allocator: std.mem.Allocator) ParseError!RESPValue {
        const result = switch (self.data[0]) {
            '*' => try parseArray(allocator, self.data),
            '$' => try parseBulkstring(self.data),
            else => return ParseError.InvalidType,
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

fn parseArray(allocator: std.mem.Allocator, data: []u8) ParseError!ParseResult(RESPValue) {
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
        list.append(allocator, parsed_item.value) catch return ParseError.TooLong;

        pos += parsed_item.consumed;
    }

    const items = list.toOwnedSlice(allocator) catch return ParseError.TooLong;
    return .{
        .value = .{ .array = items },
        .consumed = pos,
    };
}

fn parseBulkstring(data: []u8) ParseError!ParseResult(RESPValue) {
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
        return ParseError.MalformedSize;
    }

    if (data.len < pos + len + 2) {
        return ParseError.Incomplete;
    }

    const str = data[pos .. pos + len];
    // TODO: This could be redundant since we only took len size but just to be sure
    if (str.len != len) return ParseError.ExceededSize;
    pos += len;

    if (!isToken(data[pos .. pos + 2], Tokens.CRLF)) return ParseError.Incomplete;
    pos += 2;

    return .{
        .value = .{
            .bulk_string = str,
        },
        .consumed = pos,
    };
}

fn parseSize(data: []u8, token: []const u8) ParseError!ParseResult(isize) {
    var pos: usize = 0;
    if (!isToken(data[pos .. pos + 1], token)) return ParseError.IncorrectToken;

    const end = std.mem.indexOf(u8, data, Tokens.CRLF);
    if (end == null) {
        return ParseError.Incomplete;
    }

    // NOTE: We are doing pos+1 because we want to skip the token `$` or `*`
    const len = std.fmt.parseInt(isize, data[pos + 1 .. end.?], 10) catch return ParseError.MalformedSize;

    pos += end.? + 2;

    if (len < -2) return ParseError.MalformedSize;

    return .{
        .value = len,
        .consumed = pos,
    };
}

pub const Serializer = struct {
    pub fn serialize(_: Serializer, allocator: std.mem.Allocator, value: RESPValue) SerializeError![]u8 {
        return switch (value) {
            .bulk_string => return serializeBulkString(allocator, value),
            .simple_string => return serializeSimpleString(allocator, value),
            .integer => return serializeInteger(allocator, value),
            .array => return serializeArray(allocator, value),
            .simple_error => return serializeErrorString(allocator, value),
            else => {},
        };
    }

    pub fn deinit(self: Serializer, allocator: std.mem.Allocator) void {}
};

pub fn serializer() Serializer {
    return Serializer{};
}

fn serializeBulkString(allocator: std.mem.Allocator, maybe_value: ?[]const u8) SerializeError![]u8 {
    if (maybe_value == null) {
        // TODO: Here we can simply use string literal but then the client code needs to know if the result is stack memory or heap memory.
        // This makes sure that we dont free urelated memory but this does heap allocator which is not ideal
        // Improve this if better approach is found
        return std.fmt.allocPrint(allocator, "$-1\r\n", .{});
    }

    const value = maybe_value.?;
    return std.fmt.allocPrint(allocator, "${d}\r\n{s}\r\n", .{ value.len, value });
}

fn serializeSimpleString(allocator: std.mem.Allocator, value: []const u8) SerializeError![]u8 {
    return std.fmt.allocPrint(allocator, "+{s}\r\n", .{value});
}

fn serializeInteger(allocator: std.mem.Allocator, value: i64) SerializeError![]u8 {
    return std.fmt.allocPrint(allocator, ":{d}", .{value});
}

fn serializeErrorString(allocator: std.mem.Allocator, err: SerializeError) SerializeError![]u8 {
    const msg = serializerErrorMessage(err);
    return std.fmt.allocPrint(allocator, "-{}", .{msg}) catch {
        return "-ERR something went wront";
    };
}

fn serializeArray(allocator: std.mem.Allocator, maybe_value: ?[]RESPValue) SerializeError![]u8 {
    if (maybe_value == null) {
        return std.fmt.allocPrint(allocator, "*0\r\n", .{});
    }

    // TODO: Implement
    return std.fmt.allocPrint(allocator, "*0\r\n", .{});
}

fn isToken(data: []u8, token: []const u8) bool {
    return std.mem.eql(u8, data, token);
}
