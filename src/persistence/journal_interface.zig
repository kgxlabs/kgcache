// AOF state operations require a caller-held Journal session.
// Acquire Storage sessions in ascending database order before Journal.
// Record publish and abort do not manage the session.
// Loading and reconciliation are startup-only; deinit is shutdown-only.

const std = @import("std");
const object = @import("../object.zig");
const Storage = @import("../storage/interface.zig");
const PersistenceState = @import("../persistence_state.zig");
const Store = @import("../store/interface.zig");
const Manifest = @import("./manifest.zig");
const Config = @import("../config.zig");
const time = @import("../time.zig");
const Lock = @import("../lock.zig");

const JournalPersistence = @This();

ptr: *anyopaque,
vtable: *const VTable,
_lock: *Lock,

pub const Error = error{
    RewriteAlreadyInProgress,
    JournalWriteBlocked,
    MissingAofManifest,
    MissingLiveAofFile,
    MissingPendingBase,
    InvalidManifestSequence,
    BaseAlreadyOpen,
    BaseEncoderMissing,
    BaseFileMissing,
    RewriteStillRunning,
};

pub const FlushMode = enum {
    /// Flush buffered records now. Fsync still follows the configured policy.
    unconditional,
    /// Flush only when appendfsync always requires it before replying to a write.
    if_required,
};

pub const FlushOptions = struct {
    mode: FlushMode = .unconditional,
};

pub const Tx = Lock.Tx;

pub const WriteEvent = union(enum) {
    put: struct { db_index: u32, key: []const u8, value: object.Object, expires_at: ?time.UnixMs },
    remove: struct { db_index: u32, key: []const u8 },
};

pub const Record = struct {
    ptr: *anyopaque,
    event: WriteEvent,
    publish_fn: *const fn (*anyopaque, WriteEvent) void,
    abort_fn: *const fn (*anyopaque, WriteEvent) void,
    state: enum { pending, published, aborted } = .pending,

    pub fn init(
        ptr: *anyopaque,
        event: WriteEvent,
        publish_fn: *const fn (*anyopaque, WriteEvent) void,
        abort_fn: *const fn (*anyopaque, WriteEvent) void,
    ) Record {
        return .{
            .ptr = ptr,
            .event = event,
            .publish_fn = publish_fn,
            .abort_fn = abort_fn,
        };
    }

    pub fn publish(self: *Record) void {
        std.debug.assert(self.state == .pending);
        self.state = .published;
        return self.publish_fn(self.ptr, self.event);
    }

    pub fn abort(self: *Record) void {
        if (self.state != .pending) return;
        self.state = .aborted;
        self.abort_fn(self.ptr, self.event);
    }
};

pub const VTable = struct {
    prepareRecord: *const fn (*anyopaque, WriteEvent) anyerror!Record,
    flush: *const fn (*anyopaque, i64, FlushOptions) anyerror!void,
    bgRewrite: *const fn (*anyopaque, []const Storage, origin: Store.TriggerOrigin) anyerror!void,
    dueForRewrite: *const fn (*anyopaque, Config) anyerror!bool,
    finishRewrite: *const fn (*anyopaque, PersistenceState.ReapResult) anyerror!void,
    beginLoading: *const fn (*anyopaque) void,
    endLoading: *const fn (*anyopaque) void,
    reconcile: *const fn (*anyopaque, std.Io, std.mem.Allocator, std.Io.Dir, []const u8, ?Manifest.Manifest) anyerror!void,
    deinit: *const fn (*anyopaque) anyerror!void,
};

pub fn begin(self: JournalPersistence) std.Io.Cancelable!Tx {
    return self._lock.begin();
}

pub fn onWrite(self: JournalPersistence, event: WriteEvent) anyerror!void {
    var record = try self.prepareRecord(event);
    return record.publish();
}

pub fn prepareRecord(self: JournalPersistence, event: WriteEvent) anyerror!Record {
    return self.vtable.prepareRecord(self.ptr, event);
}

pub fn flush(self: JournalPersistence, now_ms: i64, options: FlushOptions) anyerror!void {
    return self.vtable.flush(self.ptr, now_ms, options);
}

pub fn bgRewrite(self: JournalPersistence, storages: []const Storage, origin: Store.TriggerOrigin) anyerror!void {
    return self.vtable.bgRewrite(self.ptr, storages, origin);
}

pub fn dueForRewrite(self: JournalPersistence, config: Config) anyerror!bool {
    return self.vtable.dueForRewrite(self.ptr, config);
}

pub fn finishRewrite(self: JournalPersistence, reap_result: PersistenceState.ReapResult) anyerror!void {
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
) anyerror!void {
    return self.vtable.reconcile(self.ptr, io, allocator, dir, filename, manifest);
}

pub fn deinit(self: JournalPersistence) anyerror!void {
    return self.vtable.deinit(self.ptr);
}
