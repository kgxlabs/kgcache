const std = @import("std");

pub const Kind = enum { base, incr };

pub const Entry = struct {
    name: []const u8,
    seq: u32,
    kind: Kind,

    pub fn format(self: Entry, writer: *std.Io.Writer) !void {
        const type_letter: []const u8 = switch (self.kind) {
            .base => "b",
            .incr => "i",
        };
        try writer.print("file {s} seq {d} type {s}\n", .{ self.name, self.seq, type_letter });
    }
};

pub const Manifest = struct {
    base: ?Entry,
    incrs: []Entry,

    pub fn format(self: Manifest, writer: *std.Io.Writer) !void {
        if (self.base) |b| try b.format(writer);
        for (self.incrs) |incr| try incr.format(writer);
    }

    /// Frees a `Manifest` returned by `read()`, whose `Entry.name`s are
    /// independently allocator-owned. Do not call this on the result of
    /// `parse()` directly -- its `Entry.name`s borrow from the `contents`
    /// passed into it, and freeing those would be undefined behaviour.
    pub fn deinit(self: Manifest, allocator: std.mem.Allocator) void {
        if (self.base) |b| allocator.free(b.name);
        for (self.incrs) |incr| allocator.free(incr.name);
        allocator.free(self.incrs);
    }
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

/// Returns `null` when `filename` does not exist. for example, a first boot with
/// appendonly just switched on, not a failure. The returned `Manifest`
/// (unlike `parse`'s) fully owns its `Entry.name` strings, since the
/// backing `contents` buffer is freed before this returns.
pub fn read(io: std.Io, allocator: std.mem.Allocator, dir: std.Io.Dir, filename: []const u8) !?Manifest {
    const contents = dir.readFileAlloc(io, filename, allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => {
            return null;
        },
        error.OutOfMemory => return Error.OutOfMemory,
        else => return Error.FailedToReadManifest,
    };
    defer allocator.free(contents);

    const borrowed = try parse(allocator, contents);
    defer allocator.free(borrowed.incrs);

    return try dupeManifest(allocator, borrowed);
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
    const serialized_string = try std.fmt.allocPrint(allocator, "{f}", .{manifest});
    defer allocator.free(serialized_string);

    const tmp_filename = try std.fmt.allocPrint(allocator, "{s}.tmp", .{filename});
    defer allocator.free(tmp_filename);

    try dir.writeFile(io, .{
        .data = serialized_string,
        .sub_path = tmp_filename,
    });

    // NOTE: we need to close the file before rename. we need to do this in isolated block for defer file.close otherwise we have to do double close which is `Undefined Behaviour`
    {
        const tmp_file = try dir.openFile(io, tmp_filename, .{ .mode = .read_write });
        defer tmp_file.close(io);
        try tmp_file.sync(io);
    }

    try dir.rename(tmp_filename, dir, filename, io);

    // NOTE: rename(2) is atomic within a directory, but the rename is itself
    // a change to the *directory's* metadata, which can sit unflushed in the
    // page cache like anything else -- without fsyncing the directory too, a
    // power loss right after the rename could still leave `filename`
    // resolving to the old contents. std.Io.Dir exposes no directory-level
    // sync in this Zig version (only File.sync), so that gap is real and not
    // covered here.
}

pub fn nextSeq(manifest: Manifest) u32 {
    var max_seq: u32 = 0;
    if (manifest.base) |b| max_seq = @max(max_seq, b.seq);
    for (manifest.incrs) |incr| max_seq = @max(max_seq, incr.seq);
    return max_seq + 1;
}

// Whoever calls these name methods, must free them also
pub fn baseName(allocator: std.mem.Allocator, append_filename: []const u8, seq: u32) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.{d}.base", .{ append_filename, seq });
}

pub fn incrName(allocator: std.mem.Allocator, append_filename: []const u8, seq: u32) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.{d}.incr", .{ append_filename, seq });
}

pub fn manifestName(allocator: std.mem.Allocator, append_filename: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.manifest", .{append_filename});
}

pub fn liveIncr(manifest: Manifest) ?Entry {
    var live: ?Entry = null;
    for (manifest.incrs) |incr| {
        if (live == null or incr.seq > live.?.seq) live = incr;
    }
    return live;
}

fn dupeManifest(allocator: std.mem.Allocator, manifest: Manifest) !Manifest {
    var base: ?Entry = null;
    if (manifest.base) |b| base = .{
        .name = try allocator.dupe(u8, b.name),
        .seq = b.seq,
        .kind = b.kind,
    };
    errdefer if (base) |b| allocator.free(b.name);

    var incrs: std.ArrayList(Entry) = .empty;
    errdefer {
        for (incrs.items) |incr| allocator.free(incr.name);
        incrs.deinit(allocator);
    }

    for (manifest.incrs) |incr| {
        try incrs.append(allocator, .{
            .name = try allocator.dupe(u8, incr.name),
            .seq = incr.seq,
            .kind = incr.kind,
        });
    }

    return .{ .base = base, .incrs = try incrs.toOwnedSlice(allocator) };
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

fn withScratchDir(comptime name: []const u8, comptime testFn: fn (std.Io, std.Io.Dir) anyerror!void) !void {
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    cwd.createDir(io, name, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer cwd.deleteTree(io, name) catch {};

    var dir = try cwd.openDir(io, name, .{});
    defer dir.close(io);

    try testFn(io, dir);
}

test "read returns null when the manifest file does not exist" {
    try withScratchDir("scratch-manifest-read-missing", struct {
        fn run(io: std.Io, dir: std.Io.Dir) !void {
            const manifest = try read(io, std.testing.allocator, dir, "appendonly.aof.manifest");
            try std.testing.expect(manifest == null);
        }
    }.run);
}

test "write then read round-trips a manifest" {
    try withScratchDir("scratch-manifest-roundtrip", struct {
        fn run(io: std.Io, dir: std.Io.Dir) !void {
            const testing = std.testing;

            var incrs = [_]Entry{.{ .name = "appendonly.aof.2.incr", .seq = 2, .kind = .incr }};
            const original: Manifest = .{
                .base = .{ .name = "appendonly.aof.1.base", .seq = 1, .kind = .base },
                .incrs = &incrs,
            };

            try write(io, testing.allocator, dir, "appendonly.aof.manifest", original);

            const loaded = try read(io, testing.allocator, dir, "appendonly.aof.manifest") orelse return error.TestUnexpectedResult;
            defer loaded.deinit(testing.allocator);

            const base = loaded.base orelse return error.TestUnexpectedResult;
            try testing.expectEqualStrings("appendonly.aof.1.base", base.name);
            try testing.expectEqual(1, base.seq);
            try testing.expectEqual(Kind.base, base.kind);

            try testing.expectEqual(1, loaded.incrs.len);
            try testing.expectEqualStrings("appendonly.aof.2.incr", loaded.incrs[0].name);
            try testing.expectEqual(2, loaded.incrs[0].seq);
        }
    }.run);
}

test "write leaves no .tmp file behind on success" {
    try withScratchDir("scratch-manifest-no-tmp", struct {
        fn run(io: std.Io, dir: std.Io.Dir) !void {
            const testing = std.testing;

            const manifest: Manifest = .{ .base = null, .incrs = &.{} };
            try write(io, testing.allocator, dir, "appendonly.aof.manifest", manifest);

            try testing.expectError(error.FileNotFound, dir.access(io, "appendonly.aof.manifest.tmp", .{}));
        }
    }.run);
}
