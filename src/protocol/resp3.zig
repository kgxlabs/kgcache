const std = @import("std");
const Resp = @import("interface.zig");

const Resp3 = @This();

var instance: Resp3 = .{};

pub fn resp() Resp {
    return .{ .ptr = &instance, .vtable = &vtable };
}

const vtable: Resp.VTable = .{
    .version = .resp3,
    .writeSimpleString = Resp.writeSimpleStringShared,
    .writeError = Resp.writeErrorShared,
    .writeInteger = Resp.writeIntegerShared,
    .writeBlobString = Resp.writeBlobStringShared,
    .writeNull = writeNull,
    .writeArray = Resp.writeArrayShared,
    .writeMap = writeMap,
};

fn writeNull(_: *anyopaque, writer: *std.Io.Writer, _: Resp.Resp2NullKind) Resp.EncodeError!void {
    try writer.writeAll("_\r\n");
}

fn writeMap(_: *anyopaque, self: Resp, writer: *std.Io.Writer, entries: []const Resp.MapEntry) Resp.EncodeError!void {
    try writer.print("%{d}\r\n", .{entries.len});
    try Resp.writeMapEntries(self, writer, entries);
}
