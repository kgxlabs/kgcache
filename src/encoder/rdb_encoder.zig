const std = @import("std");
const object = @import("../object.zig");
const time = @import("../time.zig");

const RdbEncoder = @This();

/// "KGCACHE" magic + "0000" version. Written once, at the very start of a dump.
const header = "KGCACHE0000";
const eof_marker: u8 = 0xFF;

// Every entry is tagged with its type, even though `object.Object` only has
// `.string` today: this lets future types (list/set/hash/...) join the
// format without a version bump, since a reader can always tell how much of
// what follows belongs to this entry.
const TypeTag = enum(u8) {
    string = 0x00,
};

_allocator: std.mem.Allocator,
_buffer: std.ArrayList(u8),
_checksum: std.hash.crc.Crc64Redis,

pub fn init(allocator: std.mem.Allocator) RdbEncoder {
    return .{
        ._allocator = allocator,
        ._buffer = .empty,
        ._checksum = .init(),
    };
}

pub fn deinit(self: *RdbEncoder) void {
    self._buffer.deinit(self._allocator);
}

/// Bytes accumulated so far. Only meaningful to persist once `writeFooter`
/// has run — before that the checksum it contains isn't final.
pub fn bytes(self: *const RdbEncoder) []const u8 {
    return self._buffer.items;
}

pub fn writeHeader(self: *RdbEncoder) !void {
    try self.writeRaw(header);
}

pub fn writeEntry(self: *RdbEncoder, key: []const u8, value: object.Object, exp: ?time.UnixMs) !void {
    try self.writeTypeTag(value);
    try self.writeExpiry(exp);
    try self.writeLengthPrefixed(key);
    try self.writeValue(value);
}

pub fn writeFooter(self: *RdbEncoder) !void {
    try self.writeRaw(&[_]u8{eof_marker});

    // The checksum digests everything up to and including the EOF marker,
    // so it can't digest itself — these final bytes go straight to the
    // buffer rather than through `writeRaw`.
    const checksum = self._checksum.final();
    try self._buffer.appendSlice(self._allocator, std.mem.asBytes(&checksum));
}

fn writeTypeTag(self: *RdbEncoder, value: object.Object) !void {
    const tag: TypeTag = switch (value) {
        .string => .string,
    };
    try self.writeRaw(&[_]u8{@intFromEnum(tag)});
}

fn writeExpiry(self: *RdbEncoder, exp: ?time.UnixMs) !void {
    if (exp) |expires_at| {
        try self.writeRaw(&[_]u8{1});
        try self.writeRaw(std.mem.asBytes(&expires_at));
    } else {
        try self.writeRaw(&[_]u8{0});
    }
}

fn writeValue(self: *RdbEncoder, value: object.Object) !void {
    switch (value) {
        .string => |str| try self.writeLengthPrefixed(str),
    }
}

fn writeLengthPrefixed(self: *RdbEncoder, data: []const u8) !void {
    const len: u32 = @intCast(data.len);
    try self.writeRaw(std.mem.asBytes(&len));
    try self.writeRaw(data);
}

/// The single choke point every other write goes through, so the running
/// checksum can never drift from what actually landed in `_buffer`.
fn writeRaw(self: *RdbEncoder, data: []const u8) !void {
    try self._buffer.appendSlice(self._allocator, data);
    self._checksum.update(data);
}
