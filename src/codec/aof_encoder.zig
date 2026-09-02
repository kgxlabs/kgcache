const std = @import("std");
const resp = @import("../resp.zig");
const Journal = @import("../persistence/journal_interface.zig");
const object = @import("../object.zig");
const time = @import("../time.zig");

const AofEncoder = @This();

pub const Error = std.mem.Allocator.Error;

_serializer: resp.Serializer,
_last_db: ?u32 = null,

pub fn init() AofEncoder {
    return .{ ._serializer = resp.serializer() };
}

/// Encodes a write event as the RESP command that would reproduce it on
/// replay. The AOF file is a log of client-shaped commands, not a bespoke
/// binary format, so this leans entirely on the RESP serializer that already
/// exists for talking to clients.
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

// db_index is not committed here. It only becomes true once the caller has
// actually appended `bytes` to durable storage, via commitDb below. Otherwise
// a failed append after this call would leave _last_db saying a SELECT was
// written when it never reached the buffer.
pub fn encodeWriteEvent(self: *AofEncoder, allocator: std.mem.Allocator, event: Journal.WriteEvent) Error!Encoded {
    return self.encodeCommand(allocator, eventDbIndex(event), .{ .write_event = event });
}

pub fn encodeRewriteEntry(self: *AofEncoder, allocator: std.mem.Allocator, entry: RewriteEntry) Error!Encoded {
    return self.encodeCommand(allocator, entry.db_index, .{ .rewrite_entry = entry });
}

fn encodeCommand(self: *AofEncoder, allocator: std.mem.Allocator, db_index: u32, command: Command) Error!Encoded {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    if (self._last_db == null or self._last_db.? != db_index) {
        try appendSerialized(self, allocator, &out, try toCommandItems(allocator, .{ .select = db_index }));
    }
    try appendSerialized(self, allocator, &out, try toCommandItems(allocator, command));

    return .{ .bytes = try out.toOwnedSlice(allocator), .db_index = db_index };
}

pub fn commitDb(self: *AofEncoder, db_index: u32) void {
    self._last_db = db_index;
}

pub fn resetDbTracking(self: *AofEncoder) void {
    self._last_db = null;
}

pub fn deinit(self: AofEncoder, allocator: std.mem.Allocator, encoded: []const u8) void {
    self._serializer.deinit(allocator, encoded);
}

// SELECT is never a Journal.WriteEvent. NotifierStorage never emits one
// so it stays out of that type and only exists here.
const Command = union(enum) {
    write_event: Journal.WriteEvent,
    // NOTE: splitting as separate rewrite entry beceause some aggregage data types (for example, list) can have
    // different live write vs rewrite command. For example, current list is: [a, b, c] , either
    // RPUSH mylist a b c or LPUSH c b a can build it . we dont know exactly what was the live command out of the two (or commands) that built it
    // so live write and rewrite command will be different.
    // that's why we need to split it.
    rewrite_entry: RewriteEntry,
    select: u32,
};

const CommandItem = struct { items: []resp.RESPValue, owned: ?[]const u8 = null };
// TODO: Refactor this. too bloated with implementation details
fn toCommandItems(allocator: std.mem.Allocator, cmd: Command) Error!CommandItem {
    return switch (cmd) {
        .select => |db_index| blk: {
            const db_str = try std.fmt.allocPrint(allocator, "{d}", .{db_index});
            const items = try allocator.alloc(resp.RESPValue, 2);
            items[0] = .{ .bulk_string = "SELECT" };
            items[1] = .{ .bulk_string = db_str };
            break :blk .{ .items = items, .owned = db_str };
        },
        .write_event => |event| switch (event) {
            .put => |put| switch (put.value) {
                .string => |value| try stringSetCommandItems(allocator, put.key, value, put.expires_at),
            },
            .remove => |remove| blk: {
                const items = try allocator.alloc(resp.RESPValue, 2);
                items[0] = .{ .bulk_string = "DEL" };
                items[1] = .{ .bulk_string = remove.key };
                break :blk .{ .items = items };
            },
        },
        .rewrite_entry => |entry| switch (entry.value) {
            .string => |value| try stringSetCommandItems(allocator, entry.key, value, entry.expires_at),
        },
    };
}

fn stringSetCommandItems(allocator: std.mem.Allocator, key: []const u8, value: []const u8, expires_at: ?time.UnixMs) Error!CommandItem {
    if (expires_at) |ms| {
        const ms_str = try std.fmt.allocPrint(allocator, "{d}", .{ms});
        const items = try allocator.alloc(resp.RESPValue, 5);
        items[0] = .{ .bulk_string = "SET" };
        items[1] = .{ .bulk_string = key };
        items[2] = .{ .bulk_string = value };
        items[3] = .{ .bulk_string = "PXAT" };
        items[4] = .{ .bulk_string = ms_str };
        return .{ .items = items, .owned = ms_str };
    }

    const items = try allocator.alloc(resp.RESPValue, 3);
    items[0] = .{ .bulk_string = "SET" };
    items[1] = .{ .bulk_string = key };
    items[2] = .{ .bulk_string = value };
    return .{ .items = items };
}

fn appendSerialized(self: *AofEncoder, allocator: std.mem.Allocator, out: *std.ArrayList(u8), command_item: CommandItem) Error!void {
    defer allocator.free(command_item.items);
    defer if (command_item.owned) |owned| allocator.free(owned);

    const bytes = self._serializer.serialize(allocator, .{ .array = command_item.items }) catch return Error.OutOfMemory;
    defer self._serializer.deinit(allocator, bytes);

    out.appendSlice(allocator, bytes) catch return Error.OutOfMemory;
}

fn eventDbIndex(event: Journal.WriteEvent) u32 {
    return switch (event) {
        .put => |put| put.db_index,
        .remove => |remove| remove.db_index,
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

test "a put with an expiry encodes as SET with PXAT" {
    const testing = std.testing;
    var encoder = AofEncoder.init();

    const encoded = try encoder.encodeWriteEvent(testing.allocator, putEvent(0, "foo", "bar", 123));
    defer encoder.deinit(testing.allocator, encoded.bytes);

    try testing.expect(std.mem.indexOf(u8, encoded.bytes, "SET") != null);
    try testing.expect(std.mem.indexOf(u8, encoded.bytes, "PXAT") != null);
    try testing.expect(std.mem.indexOf(u8, encoded.bytes, "123") != null);
}

test "a put without an expiry encodes as a plain SET" {
    const testing = std.testing;
    var encoder = AofEncoder.init();

    const encoded = try encoder.encodeWriteEvent(testing.allocator, putEvent(0, "foo", "bar", null));
    defer encoder.deinit(testing.allocator, encoded.bytes);

    try testing.expect(std.mem.indexOf(u8, encoded.bytes, "SET") != null);
    try testing.expect(std.mem.indexOf(u8, encoded.bytes, "PXAT") == null);
}

test "the first command after a file is opened is preceded by SELECT" {
    const testing = std.testing;
    var encoder = AofEncoder.init();

    const encoded = try encoder.encodeWriteEvent(testing.allocator, putEvent(0, "foo", "bar", null));
    defer encoder.deinit(testing.allocator, encoded.bytes);

    const select_pos = std.mem.indexOf(u8, encoded.bytes, "SELECT") orelse return error.TestUnexpectedResult;
    const set_pos = std.mem.indexOf(u8, encoded.bytes, "SET") orelse return error.TestUnexpectedResult;
    try testing.expect(select_pos < set_pos);
}

test "consecutive writes to the same db emit SELECT once" {
    const testing = std.testing;
    var encoder = AofEncoder.init();

    const first = try encoder.encodeWriteEvent(testing.allocator, putEvent(0, "foo", "bar", null));
    defer encoder.deinit(testing.allocator, first.bytes);
    encoder.commitDb(first.db_index);

    const second = try encoder.encodeWriteEvent(testing.allocator, putEvent(0, "baz", "qux", null));
    defer encoder.deinit(testing.allocator, second.bytes);

    try testing.expect(std.mem.indexOf(u8, first.bytes, "SELECT") != null);
    try testing.expect(std.mem.indexOf(u8, second.bytes, "SELECT") == null);
}

test "a write to a different db emits a new SELECT" {
    const testing = std.testing;
    var encoder = AofEncoder.init();

    const first = try encoder.encodeWriteEvent(testing.allocator, putEvent(0, "foo", "bar", null));
    defer encoder.deinit(testing.allocator, first.bytes);
    encoder.commitDb(first.db_index);

    const second = try encoder.encodeWriteEvent(testing.allocator, putEvent(1, "baz", "qux", null));
    defer encoder.deinit(testing.allocator, second.bytes);

    try testing.expect(std.mem.indexOf(u8, second.bytes, "SELECT") != null);
}

test "a failed write does not commit its db, so the next write still gets a SELECT" {
    const testing = std.testing;
    var encoder = AofEncoder.init();

    const first = try encoder.encodeWriteEvent(testing.allocator, putEvent(0, "foo", "bar", null));
    defer encoder.deinit(testing.allocator, first.bytes);
    // first.db_index is deliberately not committed here, simulating a
    // failed buffer append after a successful encode.

    const second = try encoder.encodeWriteEvent(testing.allocator, putEvent(0, "baz", "qux", null));
    defer encoder.deinit(testing.allocator, second.bytes);

    try testing.expect(std.mem.indexOf(u8, second.bytes, "SELECT") != null);
}

test "a rewrite entry encodes the complete string value as SET with PXAT" {
    const testing = std.testing;
    var encoder = AofEncoder.init();

    const encoded = try encoder.encodeRewriteEntry(testing.allocator, .{
        .db_index = 2,
        .key = "foo",
        .value = .{ .string = "bar" },
        .expires_at = 123,
    });
    defer encoder.deinit(testing.allocator, encoded.bytes);

    try testing.expectEqualStrings(
        "*2\r\n$6\r\nSELECT\r\n$1\r\n2\r\n" ++
            "*5\r\n$3\r\nSET\r\n$3\r\nfoo\r\n$3\r\nbar\r\n$4\r\nPXAT\r\n$3\r\n123\r\n",
        encoded.bytes,
    );
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
