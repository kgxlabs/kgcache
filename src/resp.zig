const std = @import("std");

const Commands = struct {
    pub const ECHO: []const u8 = "echo";
    pub const PING: []const u8 = "ping";
};

const Tokens = struct {
    pub const Array: []const u8 = "*";
    pub const BulkString: []const u8 = "$";
    pub const CR: []const u8 = "\r";
    pub const LF: []const u8 = "\n";
    pub const CRLF: []const u8 = "\r\n";
};

pub const RespValue = union(enum) {
    array: ?[]RespValue,
    bulk_string: ?[]const u8,
    simple_string: []const u8,
    integer: i64,
    simple_error: []const u8,
};

const ErrorParseRequest = error{
    NotArray,
    NotCRLF,
    NotBulkString,
    Incomplete,
    MalformedSize,
    ExceededSize,
    TooLong,
    InvalidType,
    IncorrectToken,
};

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

    pub fn parse(self: *Self, allocator: std.mem.Allocator) ErrorParseRequest!RespValue {
        const result = switch (self.data[0]) {
            '*' => try parseArray(allocator, self.data),
            '$' => try parseBulkstring(self.data),
            else => return ErrorParseRequest.InvalidType,
        };

        self._pos += result.consumed - 1;

        return result.value;
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator, value: RespValue) void {
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

fn parseArray(allocator: std.mem.Allocator, data: []u8) ErrorParseRequest!ParseResult(RespValue) {
    var list: std.ArrayList(RespValue) = .empty;
    errdefer list.deinit(allocator);

    const parsed_size = try parseSize(data, Tokens.Array);
    if (parsed_size.value == -1) {
        return .{
            .value = .{ .array = null },
            .consumed = parsed_size.consumed,
        };
    }

    var pos: usize = parsed_size.consumed - 1;
    const len: usize = @intCast(parsed_size.value);

    // TODO: This is hardcoded only for bulk_string. Refactor to support all types
    for (0..len) |_| {
        const parsed_item = try parseBulkstring(data[pos..]);
        list.append(allocator, parsed_item.value) catch return ErrorParseRequest.TooLong;

        pos += parsed_item.consumed;
    }

    const items = list.toOwnedSlice(allocator) catch return ErrorParseRequest.TooLong;
    return .{
        .value = .{ .array = items },
        .consumed = pos,
    };
}

fn parseBulkstring(data: []u8) ErrorParseRequest!ParseResult(RespValue) {
    const parsed_size = try parseSize(data, Tokens.BulkString);
    if (parsed_size.value == -1) {
        return .{
            .value = .{
                .bulk_string = null,
            },
            .consumed = parsed_size.consumed,
        };
    }

    var pos: usize = parsed_size.consumed - 1;
    const len: usize = @intCast(parsed_size.value);

    if (len < -1) {
        return ErrorParseRequest.MalformedSize;
    }

    if (data.len < pos + len + 2) {
        return ErrorParseRequest.Incomplete;
    }

    const str = data[pos .. pos + len];
    // TODO: This could be redundant since we only took len size but just to be sure
    if (str.len != len) return ErrorParseRequest.ExceededSize;
    pos += len;

    if (!isToken(data[pos .. pos + 2], Tokens.CRLF)) return ErrorParseRequest.Incomplete;
    pos += 2;

    return .{
        .value = .{
            .bulk_string = str,
        },
        .consumed = pos,
    };
}

fn parseSize(data: []u8, token: []const u8) ErrorParseRequest!ParseResult(isize) {
    var pos: usize = 0;
    if (!isToken(data[pos..1], token)) return ErrorParseRequest.IncorrectToken;
    pos += 1;

    const end = std.mem.indexOf(u8, data, Tokens.CRLF);
    if (end == null) {
        return ErrorParseRequest.Incomplete;
    }

    const len = std.fmt.parseInt(isize, data[pos..end.?], 10) catch return ErrorParseRequest.MalformedSize;
    pos += end.? + 2;

    if (len < -2) return ErrorParseRequest.MalformedSize;

    return .{
        .value = len,
        .consumed = pos,
    };
}

fn isToken(data: []u8, token: []const u8) bool {
    return std.mem.eql(u8, data, token);
}
