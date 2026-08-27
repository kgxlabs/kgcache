const std = @import("std");

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
    // Populated once `parse`'s rejection cases are implemented.
    };

pub fn read(io: std.Io, allocator: std.mem.Allocator, dir: std.Io.Dir, filename: []const u8) !?Manifest {
    _ = io;
    _ = allocator;
    _ = dir;
    _ = filename;
    @panic("TODO");
}

pub fn parse(allocator: std.mem.Allocator, contents: []const u8) Error!Manifest {
    _ = allocator;
    _ = contents;
    @panic("TODO");
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
    _ = manifest;
    @panic("TODO");
}

pub fn baseName(allocator: std.mem.Allocator, append_filename: []const u8, seq: u32) ![]u8 {
    _ = allocator;
    _ = append_filename;
    _ = seq;
    @panic("TODO");
}

pub fn incrName(allocator: std.mem.Allocator, append_filename: []const u8, seq: u32) ![]u8 {
    _ = allocator;
    _ = append_filename;
    _ = seq;
    @panic("TODO");
}

pub fn manifestName(allocator: std.mem.Allocator, append_filename: []const u8) ![]u8 {
    _ = allocator;
    _ = append_filename;
    @panic("TODO");
}
