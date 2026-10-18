const std = @import("std");

const file_limit = 1024 * 1024;
const bundle_limit = 4 * file_limit;
const entry_limit = 128;

pub fn copyFiles(io: std.Io, allocator: std.mem.Allocator, source_path: []const u8, bundle: std.Io.Dir) !void {
    const source = try std.Io.Dir.cwd().openDir(io, source_path, .{ .iterate = true });
    defer source.close(io);
    var walker = try source.walk(allocator);
    defer walker.deinit();
    var listing_buffer: [64 * 1024]u8 = undefined;
    var listing = std.Io.Writer.fixed(&listing_buffer);
    try listing.print("Limits: file={d} bytes, bundle={d} bytes, entries={d}\n", .{ file_limit, bundle_limit, entry_limit });
    defer bundle.writeFile(io, .{ .sub_path = "files.txt", .data = listing.buffered() }) catch |err| {
        std.log.err("integration: cannot save file listing: {s}", .{@errorName(err)});
    };
    var copied: usize = 0;
    var entries: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entries == entry_limit or listing.end + entry.path.len + 256 > listing_buffer.len) {
            try listing.writeAll("Remaining entries omitted: listing limit\n");
            break;
        }
        entries += 1;
        if (entry.kind != .file) {
            try listing.print("{s}\t{s}\n", .{ entry.path, @tagName(entry.kind) });
            continue;
        }
        const stat = try entry.dir.statFile(io, entry.basename, .{});
        if (stat.size > file_limit or stat.size > bundle_limit - copied) {
            try listing.print("{s}\t{d} bytes\tomitted: byte limit\n", .{ entry.path, stat.size });
            continue;
        }
        const bytes = entry.dir.readFileAlloc(io, entry.basename, allocator, .limited(file_limit)) catch |err| {
            try listing.print("{s}\t{d} bytes\tomitted: {s}\n", .{ entry.path, stat.size, @errorName(err) });
            std.log.err("integration: cannot capture {s}: {s}", .{ entry.path, @errorName(err) });
            continue;
        };
        defer allocator.free(bytes);
        if (bytes.len > bundle_limit - copied) {
            try listing.print("{s}\t{d} bytes\tomitted: byte limit\n", .{ entry.path, bytes.len });
            continue;
        }
        const target = try std.fs.path.join(allocator, &.{ "files", entry.path });
        defer allocator.free(target);
        try bundle.createDirPath(io, std.fs.path.dirname(target).?);
        try bundle.writeFile(io, .{ .sub_path = target, .data = bytes });
        copied += bytes.len;
        try listing.print("{s}\t{d} bytes\tcopied\n", .{ entry.path, bytes.len });
    }
}
