const std = @import("std");
const object = @import("../object.zig");
const Storage = @import("../storage/interface.zig");
const PersistenceState = @import("../persistence_state.zig");
const Manifest = @import("./manifest.zig");
const Config = @import("../config.zig");
const time = @import("../time.zig");

const JournalPersistence = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const Error = error{
    OutOfMemory,
    UnableToRecordWrite,
    UnableToLoad,
    UnableToRewrite,
    RewriteAlreadyInProgress,
    FailedToOpenDir,
    FailedToReadManifest,
    FailedToWriteManifest,
    FailedToOpenManifest,
    FailedToOpenIncrFile,
    FailedToWriteIncrFile,
    FailedToOpenBase,
    FailedBufferAppend,
    FailedToCloseAof,
    FailedToRewriteAof,
    FailedToReconcileAof,
};

pub const WriteEvent = union(enum) {
    put: struct { db_index: u32, key: []const u8, value: object.Object, expires_at: ?time.UnixMs },
    remove: struct { db_index: u32, key: []const u8 },
};

pub const Record = struct {
    ptr: *anyopaque,
    event: WriteEvent,
    publish_fn: *const fn (*anyopaque, WriteEvent) Error!void,
    state: enum { pending, published, aborted } = .pending,

    pub fn init(
        ptr: *anyopaque,
        event: WriteEvent,
        publish_fn: *const fn (*anyopaque, WriteEvent) Error!void,
    ) Record {
        return .{
            .ptr = ptr,
            .event = event,
            .publish_fn = publish_fn,
        };
    }

    pub fn publish(self: *Record) Error!void {
        std.debug.assert(self.state == .pending);
        try self.publish_fn(self.ptr, self.event);
        self.state = .published;
    }

    pub fn abort(self: *Record) void {
        if (self.state != .pending) return;
        self.state = .aborted;
    }
};

pub const VTable = struct {
    onWrite: *const fn (*anyopaque, WriteEvent) Error!void,
    prepareRecord: *const fn (*anyopaque, WriteEvent) Error!Record,
    flush: *const fn (*anyopaque, i64) Error!void,
    bgRewrite: *const fn (*anyopaque, []const Storage) Error!void,
    dueForRewrite: *const fn (*anyopaque, Config) bool,
    finishRewrite: *const fn (*anyopaque, PersistenceState.ReapResult) Error!void,
    beginLoading: *const fn (*anyopaque) void,
    endLoading: *const fn (*anyopaque) void,
    reconcile: *const fn (*anyopaque, std.Io, std.mem.Allocator, std.Io.Dir, []const u8, ?Manifest.Manifest) Error!void,
    deinit: *const fn (*anyopaque) Error!void,
};

pub fn onWrite(self: JournalPersistence, event: WriteEvent) Error!void {
    return self.vtable.onWrite(self.ptr, event);
}

pub fn prepareRecord(self: JournalPersistence, event: WriteEvent) Error!Record {
    return self.vtable.prepareRecord(self.ptr, event);
}

pub fn flush(self: JournalPersistence, now_ms: i64) Error!void {
    return self.vtable.flush(self.ptr, now_ms);
}

pub fn bgRewrite(self: JournalPersistence, storages: []const Storage) Error!void {
    return self.vtable.bgRewrite(self.ptr, storages);
}

pub fn dueForRewrite(self: JournalPersistence, config: Config) bool {
    return self.vtable.dueForRewrite(self.ptr, config);
}

pub fn finishRewrite(self: JournalPersistence, reap_result: PersistenceState.ReapResult) Error!void {
    return self.vtable.finishRewrite(self.ptr, reap_result);
}

pub fn beginLoading(self: JournalPersistence) void {
    return self.vtable.beginLoading(self.ptr);
}

pub fn endLoading(self: JournalPersistence) void {
    return self.vtable.endLoading(self.ptr);
}

pub fn reconcile(
    self: JournalPersistence,
    io: std.Io,
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    filename: []const u8,
    manifest: ?Manifest.Manifest,
) Error!void {
    return self.vtable.reconcile(self.ptr, io, allocator, dir, filename, manifest);
}

pub fn deinit(self: JournalPersistence) Error!void {
    return self.vtable.deinit(self.ptr);
}
