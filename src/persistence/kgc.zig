const std = @import("std");
const Snapshot = @import("./snapshot_interface.zig");
const Storage = @import("../storage/interface.zig");
const object = @import("../object.zig");
const time = @import("../time.zig");
const KgcEncoder = @import("../codec/kgc_encoder.zig");
const KgcDecoder = @import("../codec/kgc_decoder.zig");
const PersistenceState = @import("../persistence_state.zig");

const KgcBackend = @This();

const vtable: Snapshot.VTable = .{
    .save = save,
    .load = load,
};

const required_extension = ".kgc";

pub const InitError = error{InvalidExtension};

_io: std.Io,
_allocator: std.mem.Allocator,
_path: []const u8,
// Set for the duration of a single `save()` call: created in `beginDump`,
// appended to in `dumpEntry`, consumed and cleared in `endDump`.
_encoder: ?KgcEncoder = null,
_persistence_state: PersistenceState,

pub fn init(io: std.Io, allocator: std.mem.Allocator, state: PersistenceState, path: []const u8) InitError!KgcBackend {
    if (!std.mem.endsWith(u8, path, required_extension)) return InitError.InvalidExtension;

    return .{
        ._io = io,
        ._allocator = allocator,
        ._path = path,
        ._persistence_state = state,
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

    if (!self._persistence_state.tryStartKgc()) return Snapshot.Error.SaveAlreadyInProgress;

    try self.dump(self, storages);
    self._persistence_state.finishKgc();
}

pub fn bgsave(ptr: *anyopaque, storages: []const Storage) Snapshot.Error!void {
    const self: *KgcBackend = @ptrCast(@alignCast(ptr));

    if (!self._persistence_state.tryStartKgc()) return Snapshot.Error.SaveAlreadyInProgress;
}

fn dump(self: *KgcBackend, storages: []const Storage) Snapshot.Error!void {
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

pub fn load(ptr: *anyopaque, storages: []const Storage) Snapshot.Error!void {
    const self: *KgcBackend = @ptrCast(@alignCast(ptr));

    // No file yet is the normal first-boot case, not a failure: start empty.
    const data = self.readFromDisk() catch |err| switch (err) {
        error.FileNotFound => return,
        else => return Snapshot.Error.UnableToLoad,
    };
    defer self._allocator.free(data);

    var ctx: LoadContext = .{ .storages = storages };
    KgcDecoder.decode(data, &ctx, applyRecord) catch return Snapshot.Error.UnableToLoad;
}

const LoadContext = struct {
    storages: []const Storage,
};

fn applyRecord(ctx: *anyopaque, record: KgcDecoder.Record) anyerror!void {
    const self: *LoadContext = @ptrCast(@alignCast(ctx));
    if (record.db_index >= self.storages.len) return error.InvalidDbIndex;

    const target = self.storages[record.db_index];
    var tx = try target.begin();
    defer tx.end();

    _ = try target.put(record.key, record.value, .{ .expires_at = record.exp });
}

fn readFromDisk(self: *KgcBackend) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(self._io, self._path, self._allocator, .unlimited);
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

test "load does nothing when no .kgc file exists yet" {
    const testing = std.testing;
    const DefaultStorage = @import("../storage/default_storage.zig");

    var backend = DefaultStorage.init(testing.io, testing.allocator);
    var backend_storage = backend.storage();
    defer backend_storage.deinit();

    var backend_instance = try init(testing.io, testing.allocator, "missing-on-purpose.kgc");
    try backend_instance.snapshot().load(&.{backend_storage});

    try testing.expectEqual(0, backend_storage.size());
}

test "load rejects a file that isn't a valid .kgc dump" {
    const testing = std.testing;
    const DefaultStorage = @import("../storage/default_storage.zig");

    {
        var file = try std.Io.Dir.cwd().createFile(testing.io, "corrupted-on-purpose.kgc", .{});
        defer file.close(testing.io);

        var buffer: [64]u8 = undefined;
        var file_writer = file.writer(testing.io, &buffer);
        try file_writer.interface.writeAll("this is not a valid kgc file at all");
        try file_writer.flush();
    }

    var backend = DefaultStorage.init(testing.io, testing.allocator);
    var backend_storage = backend.storage();
    defer backend_storage.deinit();

    var backend_instance = try init(testing.io, testing.allocator, "corrupted-on-purpose.kgc");
    try testing.expectError(Snapshot.Error.UnableToLoad, backend_instance.snapshot().load(&.{backend_storage}));
}
