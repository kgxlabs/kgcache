const std = @import("std");
const resp = @import("../resp.zig");
const Journal = @import("../persistence/journal_interface.zig");

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

// db_index is not committed here. It only becomes true once the caller has
// actually appended `bytes` to durable storage, via commitDb below. Otherwise
// a failed append after this call would leave _last_db saying a SELECT was
// written when it never reached the buffer.
pub fn encode(self: *AofEncoder, allocator: std.mem.Allocator, event: Journal.WriteEvent) Error!Encoded {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    const db_index = eventDbIndex(event);
    if (self._last_db == null or self._last_db.? != db_index) {
        try appendSerialized(self, allocator, &out, try toCommandItems(allocator, .{ .select = db_index }));
    }
    try appendSerialized(self, allocator, &out, try toCommandItems(allocator, .{ .write = event }));

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
    write: Journal.WriteEvent,
    select: u32,
};

const CommandItem = struct { items: []resp.RESPValue, owned: ?[]const u8 = null };
fn toCommandItems(allocator: std.mem.Allocator, cmd: Command) Error!CommandItem {
    return switch (cmd) {
        .select => |db_index| blk: {
            const db_str = try std.fmt.allocPrint(allocator, "{d}", .{db_index});
            const items = try allocator.alloc(resp.RESPValue, 2);
            items[0] = .{ .bulk_string = "SELECT" };
            items[1] = .{ .bulk_string = db_str };
            break :blk .{ .items = items, .owned = db_str };
        },
        .write => |event| switch (event) {
            .put => |put| blk: {
                const value_str = switch (put.value) {
                    .string => |str| str,
                };

                if (put.expires_at) |ms| {
                    const ms_str = try std.fmt.allocPrint(allocator, "{d}", .{ms});
                    const items = try allocator.alloc(resp.RESPValue, 5);
                    items[0] = .{ .bulk_string = "SET" };
                    items[1] = .{ .bulk_string = put.key };
                    items[2] = .{ .bulk_string = value_str };
                    items[3] = .{ .bulk_string = "PXAT" };
                    items[4] = .{ .bulk_string = ms_str };
                    break :blk .{ .items = items, .owned = ms_str };
                }

                const items = try allocator.alloc(resp.RESPValue, 3);
                items[0] = .{ .bulk_string = "SET" };
                items[1] = .{ .bulk_string = put.key };
                items[2] = .{ .bulk_string = value_str };
                break :blk .{ .items = items };
            },
            .remove => |remove| blk: {
                const items = try allocator.alloc(resp.RESPValue, 2);
                items[0] = .{ .bulk_string = "DEL" };
                items[1] = .{ .bulk_string = remove.key };
                break :blk .{ .items = items };
            },
        },
    };
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

    const encoded = try encoder.encode(testing.allocator, putEvent(0, "foo", "bar", 123));
    defer encoder.deinit(testing.allocator, encoded.bytes);

    try testing.expect(std.mem.indexOf(u8, encoded.bytes, "SET") != null);
    try testing.expect(std.mem.indexOf(u8, encoded.bytes, "PXAT") != null);
    try testing.expect(std.mem.indexOf(u8, encoded.bytes, "123") != null);
}

test "a put without an expiry encodes as a plain SET" {
    const testing = std.testing;
    var encoder = AofEncoder.init();

    const encoded = try encoder.encode(testing.allocator, putEvent(0, "foo", "bar", null));
    defer encoder.deinit(testing.allocator, encoded.bytes);

    try testing.expect(std.mem.indexOf(u8, encoded.bytes, "SET") != null);
    try testing.expect(std.mem.indexOf(u8, encoded.bytes, "PXAT") == null);
}

test "the first command after a file is opened is preceded by SELECT" {
    const testing = std.testing;
    var encoder = AofEncoder.init();

    const encoded = try encoder.encode(testing.allocator, putEvent(0, "foo", "bar", null));
    defer encoder.deinit(testing.allocator, encoded.bytes);

    const select_pos = std.mem.indexOf(u8, encoded.bytes, "SELECT") orelse return error.TestUnexpectedResult;
    const set_pos = std.mem.indexOf(u8, encoded.bytes, "SET") orelse return error.TestUnexpectedResult;
    try testing.expect(select_pos < set_pos);
}

test "consecutive writes to the same db emit SELECT once" {
    const testing = std.testing;
    var encoder = AofEncoder.init();

    const first = try encoder.encode(testing.allocator, putEvent(0, "foo", "bar", null));
    defer encoder.deinit(testing.allocator, first.bytes);
    encoder.commitDb(first.db_index);

    const second = try encoder.encode(testing.allocator, putEvent(0, "baz", "qux", null));
    defer encoder.deinit(testing.allocator, second.bytes);

    try testing.expect(std.mem.indexOf(u8, first.bytes, "SELECT") != null);
    try testing.expect(std.mem.indexOf(u8, second.bytes, "SELECT") == null);
}

test "a write to a different db emits a new SELECT" {
    const testing = std.testing;
    var encoder = AofEncoder.init();

    const first = try encoder.encode(testing.allocator, putEvent(0, "foo", "bar", null));
    defer encoder.deinit(testing.allocator, first.bytes);
    encoder.commitDb(first.db_index);

    const second = try encoder.encode(testing.allocator, putEvent(1, "baz", "qux", null));
    defer encoder.deinit(testing.allocator, second.bytes);

    try testing.expect(std.mem.indexOf(u8, second.bytes, "SELECT") != null);
}

test "a failed write does not commit its db, so the next write still gets a SELECT" {
    const testing = std.testing;
    var encoder = AofEncoder.init();

    const first = try encoder.encode(testing.allocator, putEvent(0, "foo", "bar", null));
    defer encoder.deinit(testing.allocator, first.bytes);
    // first.db_index is deliberately not committed here, simulating a
    // failed buffer append after a successful encode.

    const second = try encoder.encode(testing.allocator, putEvent(0, "baz", "qux", null));
    defer encoder.deinit(testing.allocator, second.bytes);

    try testing.expect(std.mem.indexOf(u8, second.bytes, "SELECT") != null);
}
