const std = @import("std");
const CommandFrame = @import("../protocol/command_frame.zig");
const command_encoder = @import("../protocol/resp_command_encoder.zig");
const Journal = @import("../persistence/journal_interface.zig");
const object = @import("../object.zig");
const time = @import("../time.zig");

const AofEncoder = @This();

pub const Error = std.mem.Allocator.Error || error{LengthOverflow};

_last_db: ?u32 = null,

pub fn init() AofEncoder {
    return .{};
}

pub const Encoded = struct {
    bytes: []const u8,
    db_index: u32,
};

pub const RewriteEntry = struct {
    db_index: u32,
    key: []const u8,
    value: object.Object,
    expires_at: ?time.UnixMs,
};

pub fn encodeWriteEvent(self: *AofEncoder, allocator: std.mem.Allocator, event: Journal.WriteEvent) Error!Encoded {
    const db_index = switch (event) {
        .put => |put| put.db_index,
        .remove => |remove| remove.db_index,
    };

    return self.encodeCommand(allocator, db_index, .{ .write_event = event });
}

pub fn encodeRewriteEntry(self: *AofEncoder, allocator: std.mem.Allocator, entry: RewriteEntry) Error!Encoded {
    return self.encodeCommand(allocator, entry.db_index, .{ .rewrite_entry = entry });
}

fn encodeCommand(self: *AofEncoder, allocator: std.mem.Allocator, db_index: u32, command: Command) Error!Encoded {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    if (self._last_db == null or self._last_db.? != db_index) {
        try appendCommand(&output.writer, .{ .select = db_index });
    }

    try appendCommand(&output.writer, command);

    return .{ .bytes = try output.toOwnedSlice(), .db_index = db_index };
}

pub fn commitDb(self: *AofEncoder, db_index: u32) void {
    self._last_db = db_index;
}

pub fn resetDbTracking(self: *AofEncoder) void {
    self._last_db = null;
}

pub fn deinit(_: AofEncoder, allocator: std.mem.Allocator, encoded: []const u8) void {
    allocator.free(encoded);
}

const Command = union(enum) {
    write_event: Journal.WriteEvent,
    rewrite_entry: RewriteEntry,
    select: u32,
};

fn appendCommand(writer: *std.Io.Writer, command: Command) Error!void {
    switch (command) {
        .select => |db_index| {
            var buffer: [32]u8 = undefined;
            const db = std.fmt.bufPrint(&buffer, "{d}", .{db_index}) catch unreachable;
            try writeFrame(writer, .{ .name = "SELECT", .arguments = &.{db} });
        },
        .write_event => |event| switch (event) {
            .put => |put| switch (put.value) {
                .string => |value| try writeSet(writer, put.key, value, put.expires_at),
            },
            .remove => |remove| try writeFrame(writer, .{ .name = "DEL", .arguments = &.{remove.key} }),
        },
        .rewrite_entry => |entry| switch (entry.value) {
            .string => |value| try writeSet(writer, entry.key, value, entry.expires_at),
        },
    }
}

fn writeSet(writer: *std.Io.Writer, key: []const u8, value: []const u8, expires_at: ?time.UnixMs) Error!void {
    if (expires_at) |ms| {
        var buffer: [32]u8 = undefined;
        const expiration = std.fmt.bufPrint(&buffer, "{d}", .{ms}) catch unreachable;
        try writeFrame(writer, .{ .name = "SET", .arguments = &.{ key, value, "PXAT", expiration } });
    } else {
        try writeFrame(writer, .{ .name = "SET", .arguments = &.{ key, value } });
    }
}

fn writeFrame(writer: *std.Io.Writer, frame: CommandFrame) Error!void {
    command_encoder.writeCommand(writer, frame) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        error.LengthOverflow => return error.LengthOverflow,
    };
}

fn putEvent(db_index: u32, key: []const u8, value: []const u8, expires_at: ?i64) Journal.WriteEvent {
    return .{ .put = .{
        .db_index = db_index,
        .key = key,
        .value = .{ .string = value },
        .expires_at = expires_at,
    } };
}

test "a rewrite entry without expiry encodes a plain SET" {
    const testing = std.testing;
    var encoder = AofEncoder.init();

    const encoded = try encoder.encodeRewriteEntry(testing.allocator, .{
        .db_index = 0,
        .key = "key",
        .value = .{ .string = "value" },
        .expires_at = null,
    });
    defer encoder.deinit(testing.allocator, encoded.bytes);

    try testing.expectEqualStrings(
        "*2\r\n$6\r\nSELECT\r\n$1\r\n0\r\n" ++
            "*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$5\r\nvalue\r\n",
        encoded.bytes,
    );
}

test "rewrite entries track SELECT independently through commitDb" {
    const testing = std.testing;
    var encoder = AofEncoder.init();

    const first = try encoder.encodeRewriteEntry(testing.allocator, .{
        .db_index = 1,
        .key = "first",
        .value = .{ .string = "one" },
        .expires_at = null,
    });
    defer encoder.deinit(testing.allocator, first.bytes);
    encoder.commitDb(first.db_index);

    const same_db = try encoder.encodeRewriteEntry(testing.allocator, .{
        .db_index = 1,
        .key = "second",
        .value = .{ .string = "two" },
        .expires_at = null,
    });
    defer encoder.deinit(testing.allocator, same_db.bytes);

    const other_db = try encoder.encodeRewriteEntry(testing.allocator, .{
        .db_index = 2,
        .key = "third",
        .value = .{ .string = "three" },
        .expires_at = null,
    });
    defer encoder.deinit(testing.allocator, other_db.bytes);

    try testing.expect(std.mem.indexOf(u8, first.bytes, "SELECT") != null);
    try testing.expect(std.mem.indexOf(u8, same_db.bytes, "SELECT") == null);
    try testing.expect(std.mem.indexOf(u8, other_db.bytes, "SELECT") != null);
}

test "AOF preparation releases partial buffers on every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, encodeWithCleanup, .{});
}

fn encodeWithCleanup(allocator: std.mem.Allocator) !void {
    var encoder = AofEncoder.init();
    const value = "\x00\r\nvalue" ** 256;
    const encoded = try encoder.encodeWriteEvent(allocator, putEvent(2, "\x00key", value, 123));
    defer encoder.deinit(allocator, encoded.bytes);
    try std.testing.expect(std.mem.indexOf(u8, encoded.bytes, value) != null);
}
