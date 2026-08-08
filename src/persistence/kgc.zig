const std = @import("std");
const Snapshot = @import("./snapshot_interface.zig");
const Storage = @import("../storage/interface.zig");
const object = @import("../object.zig");
const time = @import("../time.zig");
const KgcEncoder = @import("../encoder/kgc_encoder.zig");

const KgcBackend = @This();

const vtable: Snapshot.VTable = .{
    .save = save,
};

const required_extension = ".kgc";

pub const InitError = error{InvalidExtension};

_io: std.Io,
_allocator: std.mem.Allocator,
_path: []const u8,
// Set for the duration of a single `save()` call: created in `beginDump`,
// appended to in `dumpEntry`, consumed and cleared in `endDump`.
_encoder: ?KgcEncoder = null,

pub fn init(io: std.Io, allocator: std.mem.Allocator, path: []const u8) InitError!KgcBackend {
    if (!std.mem.endsWith(u8, path, required_extension)) return InitError.InvalidExtension;

    return .{
        ._io = io,
        ._allocator = allocator,
        ._path = path,
    };
}

pub fn snapshot(self: *KgcBackend) Snapshot {
    return .{
        .ptr = self,
        .vtable = &vtable,
    };
}

pub fn save(ptr: *anyopaque, storages: []const Storage) Snapshot.Error!void {
    const self: *KgcBackend = @ptrCast(@alignCast(ptr));

    try self.beginDump();
    for (storages, 0..) |storage, db_index| {
        // a database with nothing in it gets no `SELECTDB`
        // section at all, rather than an empty one.
        if (storage.size() == 0) continue;

        try self.selectDb(@intCast(db_index));
        storage.forEach(self, visitEntry) catch return Snapshot.Error.UnableToSave;
    }
    try self.endDump();
}

fn visitEntry(ctx: *anyopaque, key: []const u8, value: object.Object, exp: ?time.UnixMs) anyerror!void {
    const self: *KgcBackend = @ptrCast(@alignCast(ctx));
    try self.dumpEntry(key, value, exp);
}

fn beginDump(self: *KgcBackend) Snapshot.Error!void {
    var encoder = KgcEncoder.init(self._allocator);
    encoder.writeHeader() catch return Snapshot.Error.UnableToSave;
    self._encoder = encoder;
}

fn selectDb(self: *KgcBackend, db_index: u32) Snapshot.Error!void {
    self._encoder.?.writeSelectDb(db_index) catch return Snapshot.Error.UnableToSave;
}

fn dumpEntry(self: *KgcBackend, key: []const u8, value: object.Object, exp: ?time.UnixMs) Snapshot.Error!void {
    self._encoder.?.writeEntry(key, value, exp) catch return Snapshot.Error.UnableToSave;
}

fn endDump(self: *KgcBackend) Snapshot.Error!void {
    var encoder = self._encoder orelse return Snapshot.Error.UnableToSave;
    defer encoder.deinit();
    defer self._encoder = null;

    encoder.writeFooter() catch return Snapshot.Error.UnableToSave;
    self.writeToDisk(encoder.bytes()) catch return Snapshot.Error.UnableToSave;
}

fn writeToDisk(self: *KgcBackend, data: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(self._io, self._path, .{});
    defer file.close(self._io);

    var buffer: [4096]u8 = undefined;
    var file_writer = file.writer(self._io, &buffer);
    try file_writer.interface.writeAll(data);
    try file_writer.flush();
}

test "init rejects a path without the .kgc extension" {
    const testing = std.testing;

    try testing.expectError(InitError.InvalidExtension, init(testing.io, testing.allocator, "dump.rdb"));
    try testing.expectError(InitError.InvalidExtension, init(testing.io, testing.allocator, "dump"));
    try testing.expectError(InitError.InvalidExtension, init(testing.io, testing.allocator, "dump.kgcx"));
}

test "init accepts a path with the .kgc extension" {
    const testing = std.testing;

    _ = try init(testing.io, testing.allocator, "dump.kgc");
}
