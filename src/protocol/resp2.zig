const std = @import("std");
const Resp = @import("interface.zig");

const Resp2 = @This();

var instance: Resp2 = .{};

pub fn resp() Resp {
    return .{ .ptr = &instance, .vtable = &vtable };
}

const vtable: Resp.VTable = .{
    .version = .resp2,
    .writeSimpleString = Resp.writeSimpleStringShared,
    .writeError = Resp.writeErrorShared,
    .writeInteger = Resp.writeIntegerShared,
    .writeBlobString = Resp.writeBlobStringShared,
    .writeNull = writeNull,
    .writeArray = Resp.writeArrayShared,
    .writeMap = writeMap,
};

fn writeNull(_: *anyopaque, writer: *std.Io.Writer, kind: Resp.Resp2NullKind) Resp.EncodeError!void {
    try writer.writeAll(switch (kind) {
        .bulk_string => "$-1\r\n",
        .array => "*-1\r\n",
    });
}

fn writeMap(_: *anyopaque, self: Resp, writer: *std.Io.Writer, entries: []const Resp.MapEntry) Resp.EncodeError!void {
    const count = std.math.mul(usize, entries.len, 2) catch return error.LengthOverflow;
    try writer.print("*{d}\r\n", .{count});
    try Resp.writeMapEntries(self, writer, entries);
}
