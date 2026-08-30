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

    const command_item = try toCommandItems(allocator, event);
    defer allocator.free(command_item.items);
    // the above only free the items list, we need to free for ms separately here.
    defer if (command_item.owned_ms) |ms| allocator.free(ms);

    try appendSerialized(self, allocator, &out, command_item.items);
    return out.toOwnedSlice(allocator);
}

pub fn deinit(self: AofEncoder, allocator: std.mem.Allocator, encoded: []const u8) void {
    self._serializer.deinit(allocator, encoded);
}

const CommandItem = struct { items: []resp.RESPValue, owned_ms: ?[]const u8 };
fn toCommandItems(allocator: std.mem.Allocator, event: Journal.WriteEvent) Error!CommandItem {
    return switch (event) {
        .put => |put| blk: {
            const value_str = switch (put.value) {
                .string => |str| str,
            };
            const items = try allocator.alloc(resp.RESPValue, 3);

            if (put.options.expires_at) |ms| {
                const ms_str = try std.fmt.allocPrint(allocator, "{d}", .{ms});
                items[0] = .{ .bulk_string = "SET" };
                items[1] = .{ .bulk_string = put.key };
                items[2] = .{ .bulk_string = value_str };
                items[3] = .{ .bulk_string = "PXAT" };
                items[4] = .{ .bulk_string = ms_str };
                break :blk .{ .items = items, .owned_ms = ms_str };
            }

            items[0] = .{ .bulk_string = "SET" };
            items[1] = .{ .bulk_string = put.key };
            items[2] = .{ .bulk_string = value_str };
            break :blk .{ .items = items, .owned_ms = null };
        },
        .remove => |remove| blk: {
            const items = try allocator.alloc(resp.RESPValue, 2);
            items[0] = .{ .bulk_string = "DEL" };
            items[1] = .{ .bulk_string = remove.key };
            break :blk .{ .items = items, .owned_ms = null };
        },
    };
}

fn appendSerialized(self: *AofEncoder, allocator: std.mem.Allocator, out: *std.ArrayList(u8), items: []resp.RESPValue) Error!void {
    defer allocator.free(items);

    const bytes = self._serializer.serialize(allocator, .{ .array = items }) catch return Error.OutOfMemory;
    defer self._serializer.deinit(allocator, bytes);

    out.appendSlice(allocator, bytes) catch return Error.OutOfMemory;
}

fn eventDbIndex(event: Journal.WriteEvent) u32 {
    switch (event) {
        .put => |put| put.db_index,
        .remove => |remove| remove.db_index,
    }
}
