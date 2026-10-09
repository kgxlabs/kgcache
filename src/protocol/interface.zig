const std = @import("std");
const reply = @import("reply.zig");

const Resp = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const Reply = reply.Reply;
pub const MapEntry = reply.MapEntry;
pub const Resp2NullKind = reply.Resp2NullKind;
pub const Version = enum(u8) { resp2 = 2, resp3 = 3 };
pub const EncodeError = std.Io.Writer.Error || error{ InvalidLineText, LengthOverflow };

pub const VTable = struct {
    version: Version,
    writeSimpleString: *const fn (*anyopaque, *std.Io.Writer, []const u8) EncodeError!void,
    writeError: *const fn (*anyopaque, *std.Io.Writer, []const u8) EncodeError!void,
    writeInteger: *const fn (*anyopaque, *std.Io.Writer, i64) EncodeError!void,
    writeBlobString: *const fn (*anyopaque, *std.Io.Writer, []const u8) EncodeError!void,
    writeNull: *const fn (*anyopaque, *std.Io.Writer, Resp2NullKind) EncodeError!void,
    writeArray: *const fn (*anyopaque, Resp, *std.Io.Writer, []const Reply) EncodeError!void,
    writeMap: *const fn (*anyopaque, Resp, *std.Io.Writer, []const MapEntry) EncodeError!void,
};

pub fn version(self: Resp) Version {
    return self.vtable.version;
}

pub fn writeReply(self: Resp, writer: *std.Io.Writer, value: Reply) EncodeError!void {
    try validateReply(value);
    try writeValue(self, writer, value);
}

fn validateReply(value: Reply) EncodeError!void {
    switch (value) {
        .simple_string, .error_reply => |text| {
            if (std.mem.indexOfAny(u8, text, "\r\n") != null) return error.InvalidLineText;
        },
        .blob_string => |bytes| try validateLength(bytes.len),
        .array => |items| {
            try validateLength(items.len);
            for (items) |item| try validateReply(item);
        },
        .map => |entries| {
            const flattened_count = std.math.mul(usize, entries.len, 2) catch return error.LengthOverflow;
            try validateLength(flattened_count);
            for (entries) |entry| {
                try validateReply(entry.key);
                try validateReply(entry.value);
            }
        },
        .null_value, .integer => {},
    }
}

fn validateLength(length: usize) EncodeError!void {
    if (std.math.cast(i64, length) == null) return error.LengthOverflow;
}

fn writeValue(self: Resp, writer: *std.Io.Writer, value: Reply) EncodeError!void {
    switch (value) {
        .simple_string => |text| try self.vtable.writeSimpleString(self.ptr, writer, text),
        .error_reply => |text| try self.vtable.writeError(self.ptr, writer, text),
        .integer => |integer| try self.vtable.writeInteger(self.ptr, writer, integer),
        .blob_string => |bytes| try self.vtable.writeBlobString(self.ptr, writer, bytes),
        .null_value => |kind| try self.vtable.writeNull(self.ptr, writer, kind),
        .array => |items| try self.vtable.writeArray(self.ptr, self, writer, items),
        .map => |entries| try self.vtable.writeMap(self.ptr, self, writer, entries),
    }
}

pub fn writeSimpleStringShared(_: *anyopaque, writer: *std.Io.Writer, text: []const u8) EncodeError!void {
    try writer.writeAll("+");
    try writer.writeAll(text);
    try writer.writeAll("\r\n");
}

pub fn writeErrorShared(_: *anyopaque, writer: *std.Io.Writer, text: []const u8) EncodeError!void {
    try writer.writeAll("-");
    try writer.writeAll(text);
    try writer.writeAll("\r\n");
}

pub fn writeIntegerShared(_: *anyopaque, writer: *std.Io.Writer, value: i64) EncodeError!void {
    try writer.print(":{d}\r\n", .{value});
}

pub fn writeBlobStringShared(_: *anyopaque, writer: *std.Io.Writer, bytes: []const u8) EncodeError!void {
    try writer.print("${d}\r\n", .{bytes.len});
    try writer.writeAll(bytes);
    try writer.writeAll("\r\n");
}

pub fn writeArrayShared(_: *anyopaque, self: Resp, writer: *std.Io.Writer, items: []const Reply) EncodeError!void {
    try writer.print("*{d}\r\n", .{items.len});
    for (items) |item| try writeValue(self, writer, item);
}

pub fn writeMapEntries(self: Resp, writer: *std.Io.Writer, entries: []const MapEntry) EncodeError!void {
    for (entries) |entry| {
        try writeValue(self, writer, entry.key);
        try writeValue(self, writer, entry.value);
    }
}
