const std = @import("std");
const helpers = @import("../helpers.zig");

pub const Kind = enum { base, incr };

pub const Entry = struct {
    name: []const u8,
    seq: u32,
    kind: Kind,
};

pub const Manifest = struct {
    base: ?Entry,
    incrs: []Entry,
};

pub const Error = error{
    MalformedLine,
    MultipleBaseRecords,
    DuplicateSeq,
    UnknownType,
    NonAscendingIncrSeq,
    OutOfMemory,
    FailedToReadManifest,
};

pub fn read(io: std.Io, allocator: std.mem.Allocator, dir: std.Io.Dir, filename: []const u8) !?Manifest {
    const file_exists = try helpers.fileExists(io, dir, filename);
    if (!file_exists) return null;

    const contents = dir.readFileAlloc(io, filename, allocator, .unlimited) catch return Error.FailedToReadManifest;
    return parse(allocator, contents);
}

/// `Entry.name` borrows directly from `contents`, so `contents` must
/// outlive the returned `Manifest`.
pub fn parse(allocator: std.mem.Allocator, contents: []const u8) Error!Manifest {
    var base: ?Entry = null;
    var incrs: std.ArrayList(Entry) = .empty;
    errdefer incrs.deinit(allocator);
    var last_incr_seq: ?u32 = null;

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;

        var tokens = std.mem.tokenizeAny(u8, line, " \t");

        const file_keyword = tokens.next() orelse return Error.MalformedLine;
        if (!std.mem.eql(u8, file_keyword, "file")) return Error.MalformedLine;

        const name = tokens.next() orelse return Error.MalformedLine;

        const seq_keyword = tokens.next() orelse return Error.MalformedLine;
        if (!std.mem.eql(u8, seq_keyword, "seq")) return Error.MalformedLine;

        const seq_str = tokens.next() orelse return Error.MalformedLine;
        const seq = std.fmt.parseInt(u32, seq_str, 10) catch return Error.MalformedLine;

        const type_keyword = tokens.next() orelse return Error.MalformedLine;
        if (!std.mem.eql(u8, type_keyword, "type")) return Error.MalformedLine;

        const type_str = tokens.next() orelse return Error.MalformedLine;
        if (tokens.next() != null) return Error.MalformedLine;

        const kind: Kind = if (std.mem.eql(u8, type_str, "b"))
            .base
        else if (std.mem.eql(u8, type_str, "i"))
            .incr
        else
            return Error.UnknownType;

        const entry: Entry = .{ .name = name, .seq = seq, .kind = kind };

        // Since we must only have one base at a time, we dont need to set it's seq as last_incr_seq
        switch (kind) {
            .base => {
                if (base != null) return Error.MultipleBaseRecords;
                base = entry;
            },
            .incr => {
                if (last_incr_seq != null and seq <= last_incr_seq.?) return Error.NonAscendingIncrSeq;
                last_incr_seq = seq;
                incrs.append(allocator, entry) catch return Error.OutOfMemory;
            },
        }
    }

    if (base) |b| {
        for (incrs.items) |incr| {
            if (incr.seq == b.seq) return Error.DuplicateSeq;
        }
    }

    return .{ .base = base, .incrs = try incrs.toOwnedSlice(allocator) };
}

/// Atomically replaces `dir/filename` with `manifest`'s serialized form:
/// write a `.tmp` file, fsync it, rename it into place.
pub fn write(io: std.Io, allocator: std.mem.Allocator, dir: std.Io.Dir, filename: []const u8, manifest: Manifest) !void {
    _ = io;
    _ = allocator;
    _ = dir;
    _ = filename;
    _ = manifest;
    @panic("TODO");
}

pub fn nextSeq(manifest: Manifest) u32 {
    var max_seq: u32 = 0;
    if (manifest.base) |b| max_seq = @max(max_seq, b.seq);
    for (manifest.incrs) |incr| max_seq = @max(max_seq, incr.seq);
    return max_seq + 1;
}

pub fn baseName(allocator: std.mem.Allocator, append_filename: []const u8, seq: u32) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.{d}.base", .{ append_filename, seq });
}

pub fn incrName(allocator: std.mem.Allocator, append_filename: []const u8, seq: u32) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.{d}.incr", .{ append_filename, seq });
}

pub fn manifestName(allocator: std.mem.Allocator, append_filename: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.manifest", .{append_filename});
}

test "parse reads a manifest with a base and two incrs, in order" {
    const testing = std.testing;

    const contents =
        \\file appendonly.aof.1.base seq 1 type b
        \\file appendonly.aof.2.incr seq 2 type i
        \\file appendonly.aof.3.incr seq 3 type i
    ;

    const manifest = try parse(testing.allocator, contents);
    defer testing.allocator.free(manifest.incrs);

    const base = manifest.base orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("appendonly.aof.1.base", base.name);
    try testing.expectEqual(1, base.seq);
    try testing.expectEqual(Kind.base, base.kind);

    try testing.expectEqual(2, manifest.incrs.len);
    try testing.expectEqualStrings("appendonly.aof.2.incr", manifest.incrs[0].name);
    try testing.expectEqual(2, manifest.incrs[0].seq);
    try testing.expectEqual(Kind.incr, manifest.incrs[0].kind);
    try testing.expectEqualStrings("appendonly.aof.3.incr", manifest.incrs[1].name);
    try testing.expectEqual(3, manifest.incrs[1].seq);
}

test "parse reads a manifest with no base yet" {
    const testing = std.testing;

    const contents = "file appendonly.aof.1.incr seq 1 type i";

    const manifest = try parse(testing.allocator, contents);
    defer testing.allocator.free(manifest.incrs);

    try testing.expect(manifest.base == null);
    try testing.expectEqual(1, manifest.incrs.len);
    try testing.expectEqualStrings("appendonly.aof.1.incr", manifest.incrs[0].name);
}

test "parse rejects two base records" {
    const testing = std.testing;

    const contents =
        \\file appendonly.aof.1.base seq 1 type b
        \\file appendonly.aof.2.base seq 2 type b
    ;

    try testing.expectError(Error.MultipleBaseRecords, parse(testing.allocator, contents));
}

test "parse rejects a duplicate seq" {
    const testing = std.testing;

    const contents =
        \\file appendonly.aof.2.base seq 2 type b
        \\file appendonly.aof.2.incr seq 2 type i
    ;

    try testing.expectError(Error.DuplicateSeq, parse(testing.allocator, contents));
}

test "parse rejects an unknown type letter" {
    const testing = std.testing;

    const contents = "file appendonly.aof.1.base seq 1 type x";

    try testing.expectError(Error.UnknownType, parse(testing.allocator, contents));
}

test "nextSeq is one past the highest seq of either kind" {
    const testing = std.testing;

    try testing.expectEqual(1, nextSeq(.{ .base = null, .incrs = &.{} }));

    var incr_below_base = [_]Entry{.{ .name = "i", .seq = 2, .kind = .incr }};
    try testing.expectEqual(4, nextSeq(.{
        .base = .{ .name = "b", .seq = 3, .kind = .base },
        .incrs = &incr_below_base,
    }));

    var incr_above_base = [_]Entry{.{ .name = "i", .seq = 5, .kind = .incr }};
    try testing.expectEqual(6, nextSeq(.{
        .base = .{ .name = "b", .seq = 2, .kind = .base },
        .incrs = &incr_above_base,
    }));
}

test "baseName formats the base filename" {
    const testing = std.testing;

    const name = try baseName(testing.allocator, "appendonly.aof", 1);
    defer testing.allocator.free(name);

    try testing.expectEqualStrings("appendonly.aof.1.base", name);
}

test "incrName formats the incr filename" {
    const testing = std.testing;

    const name = try incrName(testing.allocator, "appendonly.aof", 2);
    defer testing.allocator.free(name);

    try testing.expectEqualStrings("appendonly.aof.2.incr", name);
}

test "manifestName formats the manifest filename" {
    const testing = std.testing;

    const name = try manifestName(testing.allocator, "appendonly.aof");
    defer testing.allocator.free(name);

    try testing.expectEqualStrings("appendonly.aof.manifest", name);
}
