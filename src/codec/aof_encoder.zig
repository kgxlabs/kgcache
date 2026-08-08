const std = @import("std");
const resp = @import("../resp.zig");
const Journal = @import("../persistence/journal_interface.zig");

const AofEncoder = @This();

pub const Error = std.mem.Allocator.Error;

_serializer: resp.Serializer,

pub fn init() AofEncoder {
    return .{ ._serializer = resp.serializer() };
}

/// Encodes a write event as the RESP command that would reproduce it on
/// replay. The AOF file is a log of client-shaped commands, not a bespoke
/// binary format, so this leans entirely on the RESP serializer that already
/// exists for talking to clients.
///
/// TODO: `db_index` is not yet reflected as a `SELECT` command, and `put`
/// options (TTL/KEEPTTL) are not yet re-encoded — every entry currently
/// replays as a plain `SET`.
pub fn encode(self: AofEncoder, allocator: std.mem.Allocator, event: Journal.WriteEvent) Error![]const u8 {
    const items = try toCommandItems(allocator, event);
    defer allocator.free(items);

    return self._serializer.serialize(allocator, .{ .array = items }) catch return Error.OutOfMemory;
}

pub fn deinit(self: AofEncoder, allocator: std.mem.Allocator, encoded: []const u8) void {
    self._serializer.deinit(allocator, encoded);
}

fn toCommandItems(allocator: std.mem.Allocator, event: Journal.WriteEvent) Error![]resp.RESPValue {
    return switch (event) {
        .put => |put| blk: {
            const value_str = switch (put.value) {
                .string => |str| str,
            };
            const items = try allocator.alloc(resp.RESPValue, 3);
            items[0] = .{ .bulk_string = "SET" };
            items[1] = .{ .bulk_string = put.key };
            items[2] = .{ .bulk_string = value_str };
            break :blk items;
        },
        .remove => |remove| blk: {
            const items = try allocator.alloc(resp.RESPValue, 2);
            items[0] = .{ .bulk_string = "DEL" };
            items[1] = .{ .bulk_string = remove.key };
            break :blk items;
        },
    };
}
