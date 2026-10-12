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
    .writeVerbatim = writeVerbatim,
    .writeNull = writeNull,
    .writeArray = Resp.writeArrayShared,
    .writeMap = writeMap,
};

fn writeNull(_: *anyopaque, writer: *std.Io.Writer, _: Resp.Resp2NullKind) Resp.EncodeError!void {
    try writer.writeAll("_\r\n");
}

fn writeVerbatim(_: *anyopaque, writer: *std.Io.Writer, text: []const u8) Resp.EncodeError!void {
    const length = try Resp.verbatimLength(text.len);
    try writer.print("={d}\r\n", .{length});
    try writer.writeAll(Resp.verbatim_prefix);
    try writer.writeAll(text);
    try writer.writeAll("\r\n");
}

fn writeMap(_: *anyopaque, self: Resp, writer: *std.Io.Writer, entries: []const Resp.MapEntry) Resp.EncodeError!void {
    try writer.print("%{d}\r\n", .{entries.len});
    try Resp.writeMapEntries(self, writer, entries);
}
