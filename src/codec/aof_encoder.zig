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
pub fn encode(self: *AofEncoder, allocator: std.mem.Allocator, event: Journal.WriteEvent) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    const db_index = eventDbIndex(event);
    if (self._last_db == null or self._last_db.? != db_index) {
        try appendSerialized(self, allocator, &out, try toCommandItems(allocator, .{ .select = db_index }));
        self._last_db = db_index;
    }
    try appendSerialized(self, allocator, &out, try toCommandItems(allocator, .{ .write = event }));

    return out.toOwnedSlice(allocator);
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

                if (put.options.expires_at) |ms| {
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
