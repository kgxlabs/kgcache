const std = @import("std");
const object = @import("../object.zig");
const time = @import("../time.zig");

const KgcDecoder = @This();

const header = "KGCACHE0000";
const magic = header[0..7];
const version = header[7..11];
const checksum_len = 8;
const eof_marker_len = 1;
const min_file_len = header.len + eof_marker_len + checksum_len;

const Opcode = enum(u8) {
    select_db = 0xFE,
    eof = 0xFF,
};

const TypeTag = enum(u8) {
    string = 0x00,
};

pub const Error = error{
    Truncated,
    InvalidMagic,
    UnsupportedVersion,
    ChecksumMismatch,
    UnknownTypeTag,
    InvalidEntry,
};

pub const Record = struct {
    db_index: u32,
    key: []const u8,
    value: object.Object,
    exp: ?time.UnixMs,
};

/// Walks a complete `.kgc` file's bytes (as produced by `KgcEncoder`),
/// validating the header and checksum up front, then calling `visit` once
/// per entry with the database it belongs to.
///
/// `data` must outlive the call: `Record.key`/`.value` borrow directly from
/// it rather than copying. That's safe because the only caller
/// (`KgcBackend.load`) hands them straight to `Storage.put`, which makes its
/// own owned copies immediately -- mirroring how `KgcEncoder` never owns the
/// bytes it's given either, since `Storage` already owns them upstream.
pub fn decode(data: []const u8, ctx: *anyopaque, visit: *const fn (ctx: *anyopaque, record: Record) anyerror!void) Error!void {
    if (data.len < min_file_len) return Error.Truncated;
    if (!std.mem.eql(u8, data[0..magic.len], magic)) return Error.InvalidMagic;
    if (!std.mem.eql(u8, data[magic.len..header.len], version)) return Error.UnsupportedVersion;

    const eof_pos = data.len - checksum_len - eof_marker_len;
    if (data[eof_pos] != @intFromEnum(Opcode.eof)) return Error.Truncated;

    const expected_checksum = std.mem.bytesToValue(u64, data[data.len - checksum_len ..]);
    var checksum: std.hash.crc.Crc64Redis = .init();
    checksum.update(data[0 .. eof_pos + eof_marker_len]);
    if (checksum.final() != expected_checksum) return Error.ChecksumMismatch;

    var cursor: Cursor = .{ .data = data, .pos = header.len, .end = eof_pos };
    var db_index: u32 = 0;

    while (cursor.pos < cursor.end) {
        const tag = try cursor.readByte();

        if (tag == @intFromEnum(Opcode.select_db)) {
            db_index = try cursor.readU32();
            continue;
        }

        const type_tag = std.enums.fromInt(TypeTag, tag) orelse return Error.UnknownTypeTag;

        const has_expiry = try cursor.readByte();
        const exp: ?time.UnixMs = switch (has_expiry) {
            0 => null,
            1 => try cursor.readI64(),
            else => return Error.InvalidEntry,
        };

        const key = try cursor.readLengthPrefixed();
        const value: object.Object = switch (type_tag) {
            .string => .{ .string = try cursor.readLengthPrefixed() },
        };

        visit(ctx, .{
            .db_index = db_index,
            .key = key,
            .value = value,
            .exp = exp,
        }) catch return Error.InvalidEntry;
    }
}

// The read-side mirror of `KgcEncoder`'s `writeRaw`: every field read goes
// through one of these, so bounds-checking against `end` (the position of
// the `EOF` marker) never needs repeating at each call site.
const Cursor = struct {
    data: []const u8,
    pos: usize,
    end: usize,

    fn readByte(self: *Cursor) Error!u8 {
        const bytes = try self.readBytes(1);
        return bytes[0];
    }

    fn readU32(self: *Cursor) Error!u32 {
        return std.mem.bytesToValue(u32, try self.readBytes(4));
    }

    fn readI64(self: *Cursor) Error!i64 {
        return std.mem.bytesToValue(i64, try self.readBytes(8));
    }

    fn readLengthPrefixed(self: *Cursor) Error![]const u8 {
        const len = try self.readU32();
        return self.readBytes(len);
    }

    fn readBytes(self: *Cursor, len: usize) Error![]const u8 {
        if (self.pos + len > self.end) return Error.Truncated;
        const bytes = self.data[self.pos .. self.pos + len];
        self.pos += len;
        return bytes;
    }
};

test "decode rejects an entry with an unrecognized type tag" {
    const testing = std.testing;

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(testing.allocator);
    try body.appendSlice(testing.allocator, header);
    try body.append(testing.allocator, 0x7F); // not a recognized TypeTag
    try body.append(testing.allocator, @intFromEnum(Opcode.eof));

    var checksum: std.hash.crc.Crc64Redis = .init();
    checksum.update(body.items);
    const checksum_value = checksum.final();
    try body.appendSlice(testing.allocator, std.mem.asBytes(&checksum_value));

    try testing.expectError(Error.UnknownTypeTag, decode(body.items, undefined, noopVisit));
}

fn noopVisit(_: *anyopaque, _: Record) anyerror!void {}
