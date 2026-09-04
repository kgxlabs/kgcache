pub const JournalPersistence = @import("persistence/journal_interface.zig");
pub const SnapshotPersistence = @import("persistence/snapshot_interface.zig");
pub const KgcPersistence = @import("persistence/kgc.zig");
pub const AofPersistence = @import("persistence/aof.zig");
pub const AofManifest = @import("persistence/manifest.zig");
pub const AofLoader = @import("persistence/aof_loader.zig");

/// The two persistence handles passed into the storage stack at startup:
/// - `kgc` (always present — `SAVE` must always work) is handed to `Store`,
///   since a snapshot needs a whole-dataset handle, not a per-write hook.
/// - `aof` (optional) is handed to `NotifierStorage` to record writes and to
///   `MemoryStore` so `BGREWRITEAOF` can reach it.
pub const Persistence = struct {
    kgc: SnapshotPersistence,
    aof: ?JournalPersistence,
};
