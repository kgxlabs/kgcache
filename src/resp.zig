const std = @import("std");
const testing = std.testing;

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

    // AOF replay treats `Incomplete` as an unfinished command at the end of the file.
    // It treats every other error as corrupted data.
    // The parser also returns `Incomplete` when a bulk string ends with an invalid CRLF, because it cannot tell these two cases apart.
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

    if (len < -2) return RESPError.MalformedSize;

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
        return std.fmt.allocPrint(allocator, "*0\r\n", .{});
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

test "parser and serializer preserve allocation failure sources" {
    var failing_parser_allocator = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var p = parser("*1\r\n$4\r\nPING\r\n");
    try testing.expectError(error.OutOfMemory, p.parse(failing_parser_allocator.allocator()));

    var failing_serializer_allocator = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, serializer().serialize(failing_serializer_allocator.allocator(), .{ .simple_string = "OK" }));
}

test "parse array with one bulk string" {
    var p = parser("*1\r\n$7\r\nCOMMAND\r\n");
    const commands = try p.parse(testing.allocator);
    defer p.deinit(testing.allocator, commands);

    const items = try expectArray(commands, 1);
    try expectBulkString(items[0], "COMMAND");
}

test "parse array with two bulk strings" {
    var p = parser("*2\r\n$4\r\nECHO\r\n$5\r\nhello\r\n");
    const commands = try p.parse(testing.allocator);
    defer p.deinit(testing.allocator, commands);

    const items = try expectArray(commands, 2);
    try expectBulkString(items[0], "ECHO");
    try expectBulkString(items[1], "hello");
}

test "parse array with three bulk strings" {
    var p = parser("*3\r\n$3\r\nSET\r\n$4\r\nname\r\n$3\r\nfoo\r\n");
    const commands = try p.parse(testing.allocator);
    defer p.deinit(testing.allocator, commands);

    const items = try expectArray(commands, 3);
    try expectBulkString(items[0], "SET");
    try expectBulkString(items[1], "name");
    try expectBulkString(items[2], "foo");
}

test "parse array with mixed RESP values" {
    var p = parser("*3\r\n+OK\r\n:123\r\n-ERR unknown command\r\n");
    const values = try p.parse(testing.allocator);
    defer p.deinit(testing.allocator, values);

    const items = try expectArray(values, 3);
    try expectSimpleString(items[0], "OK");
    try expectInteger(items[1], 123);
    try expectSimpleError(items[2], "ERR unknown command");
}

test "parse null bulk string" {
    var p = parser("$-1\r\n");
    const value = try p.parse(testing.allocator);
    defer p.deinit(testing.allocator, value);

    switch (value) {
        .bulk_string => |maybe_value| try testing.expectEqual(@as(?[]const u8, null), maybe_value),
        else => return error.TestUnexpectedResult,
    }
}

test "serialize bulk string" {
    try expectSerialized(.{ .bulk_string = "hello" }, "$5\r\nhello\r\n");
}

test "serialize null bulk string" {
    try expectSerialized(.{ .bulk_string = null }, "$-1\r\n");
}

test "serialize simple values" {
    try expectSerialized(.{ .simple_string = "OK" }, "+OK\r\n");
    try expectSerialized(.{ .integer = 123 }, ":123\r\n");
    try expectSerialized(.{ .simple_error = "ERR unknown command" }, "-ERR unknown command\r\n");
}

test "serialize array" {
    var values = [_]RESPValue{
        .{ .bulk_string = "ECHO" },
        .{ .bulk_string = "hello" },
    };

    try expectSerialized(.{ .array = &values }, "*2\r\n$4\r\nECHO\r\n$5\r\nhello\r\n");
}

test "reject unknown RESP type" {
    var p = parser("!\r\n");

    try testing.expectError(RESPError.InvalidType, p.parse(testing.allocator));
}

test "reject malformed bulk string length" {
    var p = parser("$abc\r\nhello\r\n");

    try testing.expectError(RESPError.MalformedSize, p.parse(testing.allocator));
}

test "reject incomplete bulk string" {
    var p = parser("$5\r\nhel");

    try testing.expectError(RESPError.Incomplete, p.parse(testing.allocator));
}

test "reject incomplete request" {
    var p = parser("*1\r\n");
    try testing.expectError(RESPError.Incomplete, p.parse(testing.allocator));
}

test "next walks two commands back to back" {
    var p = parser("+OK\r\n:42\r\n");

    const first = (try p.next(testing.allocator)).?;
    defer p.deinit(testing.allocator, first);
    try expectSimpleString(first, "OK");

    const second = (try p.next(testing.allocator)).?;
    defer p.deinit(testing.allocator, second);
    try expectInteger(second, 42);
}

test "next returns null at the end of the buffer" {
    var p = parser("+OK\r\n");

    const value = (try p.next(testing.allocator)).?;
    defer p.deinit(testing.allocator, value);

    try testing.expect(try p.next(testing.allocator) == null);
}

test "next returns null immediately for an empty buffer" {
    var p = parser("");

    try testing.expect(try p.next(testing.allocator) == null);
}

test "next on a truncated final command leaves position at its start" {
    const first_command = "+OK\r\n";
    var p = parser(first_command ++ "$5\r\nhel");

    const first = (try p.next(testing.allocator)).?;
    defer p.deinit(testing.allocator, first);

    try testing.expectError(RESPError.Incomplete, p.next(testing.allocator));
    try testing.expectEqual(first_command.len, p._pos);
}

test "next parses a command after a valid bulk string" {
    var p = parser("$5\r\nhello\r\n+OK\r\n");

    const first = (try p.next(testing.allocator)).?;
    defer p.deinit(testing.allocator, first);
    try expectBulkString(first, "hello");

    const second = (try p.next(testing.allocator)).?;
    defer p.deinit(testing.allocator, second);
    try expectSimpleString(second, "OK");
}

fn expectArray(value: RESPValue, expected_len: usize) ![]RESPValue {
    switch (value) {
        .array => |maybe_items| {
            const items = maybe_items orelse return error.TestUnexpectedResult;
            try testing.expectEqual(expected_len, items.len);
            return items;
        },
        else => return error.TestUnexpectedResult,
    }
}

fn expectSimpleString(value: RESPValue, expected: []const u8) !void {
    switch (value) {
        .simple_string => |actual| try testing.expectEqualStrings(expected, actual),
        else => return error.TestUnexpectedResult,
    }
}

fn expectInteger(value: RESPValue, expected: i64) !void {
    switch (value) {
        .integer => |actual| try testing.expectEqual(expected, actual),
        else => return error.TestUnexpectedResult,
    }
}

fn expectSimpleError(value: RESPValue, expected: []const u8) !void {
    switch (value) {
        .simple_error => |actual| try testing.expectEqualStrings(expected, actual),
        else => return error.TestUnexpectedResult,
    }
}

fn expectBulkString(value: RESPValue, expected: []const u8) !void {
    switch (value) {
        .bulk_string => |maybe_value| {
            const actual = maybe_value orelse return error.TestUnexpectedResult;
            try testing.expectEqualStrings(expected, actual);
        },
        else => return error.TestUnexpectedResult,
    }
}

fn expectSerialized(value: RESPValue, expected: []const u8) !void {
    const s = serializer();
    const actual = try s.serialize(testing.allocator, value);
    defer s.deinit(testing.allocator, actual);

    try testing.expectEqualStrings(expected, actual);
}
