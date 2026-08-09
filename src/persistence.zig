pub const JournalPersistence = @import("persistence/journal_interface.zig");
pub const SnapshotPersistence = @import("persistence/snapshot_interface.zig");
pub const KgcPersistence = @import("persistence/kgc.zig");
pub const AofPersistence = @import("persistence/aof.zig");

/// The two persistence handles threaded into the storage stack at startup.
/// They are consumed by two different layers, not one:
/// - `kgc` (always present — `SAVE` must always work) is handed to `Store`,
///   since a snapshot needs a whole-dataset handle, not a per-write hook.
/// - `aof` (optional) is handed to `NotifierStorage`, since journaling needs
///   to observe every write as it happens, including silent lazy-expiration
///   removals that only the storage wrapper can see.
pub const Persistence = struct {
    kgc: SnapshotPersistence,
    aof: ?JournalPersistence,
};
