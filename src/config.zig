const std = @import("std");

const Config = @This();

/// One `save <seconds> <changes>` rule. The directive may repeat; ANY rule
/// whose condition is met (>= `changes` writes in the last `seconds`
/// seconds since the last save) triggers an automatic BGSAVE -- rules are
/// OR'd together, same as Redis.
pub const SaveRule = struct {
    seconds: i64,
    changes: u32,
};

/// How often the AOF is fsync'd to disk.
/// `always`: before every +OK, safest  and slowest.
/// `everysec`: (default): fsync at most once a second.
/// `no`: never fsync explicitly, let the OS decide -- fastest, weakest.
pub const AppendFsync = enum { always, everysec, no };

bind_address: []const u8 = "127.0.0.1",
port: u16 = 6379,
reuse_address: bool = true,
connection_buffer_size: usize = 1024,
num_databases: usize = 16,
/// Shared persistence directory, resolved from the process working directory.
dir: []const u8 = ".",
/// Snapshot filename within `dir`. Must end in `.kgc`.
dbfilename: []const u8 = "dump.kgc",
cron_interval_ms: i64 = 100,
active_expire_budget_ms: i8 = 10,
active_expire_batch_size: i8 = 20,
active_expire_threshold_percent: i8 = 25,
exclusive_bg_persistence: bool = true,
/// No `save` line means no automatic BGSAVE triggering at all (matches
/// Redis's `save ""` meaning "disable automatic saving").
save_rules: []const SaveRule = &.{},
append_only: bool = false,
/// A *base* name, not a real file: the files on disk derive from it
/// (e.g. `appendonly.aof.1.base`, `appendonly.aof.2.incr`,
/// `appendonly.aof.manifest`).
append_filename: []const u8 = "appendonly.aof",
/// Name of the directory holding all AOF files within `dir`.
/// kgcache owns this directory entirely: an interrupted rewrite can leave
/// orphan files behind, and cleaning those up is only safe if nothing else
/// shares the directory.
append_dirname: []const u8 = "appendonlydir",
append_fsync: AppendFsync = .everysec,
/// `auto-aof-rewrite-percentage 0` means never rewrite automatically; but BGREWRITEAOF by hand still works.
auto_aof_rewrite_percentage: u32 = 100,
auto_aof_rewrite_min_size: usize = 67108864,
aof_load_truncated: bool = true,
bgsave_retry_delay_ms: i64 = 5000,

pub fn default() Config {
    return .{};
}

pub fn validateDir(value: []const u8) error{InvalidValue}!void {
    if (value.len == 0 or std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidValue;
}

pub fn validateDbfilename(value: []const u8) error{InvalidValue}!void {
    if (!isBasename(value) or !std.mem.endsWith(u8, value, ".kgc")) return error.InvalidValue;
}

pub fn validateAppendDirname(value: []const u8) error{InvalidValue}!void {
    if (!isBasename(value)) return error.InvalidValue;
}

fn isBasename(value: []const u8) bool {
    return value.len > 0 and
        !std.mem.eql(u8, value, ".") and
        !std.mem.eql(u8, value, "..") and
        std.mem.indexOfAny(u8, value, "/\\\x00") == null;
}

fn validatePersistence(self: Config) error{InvalidValue}!void {
    try validateDir(self.dir);
    try validateDbfilename(self.dbfilename);
    try validateAppendDirname(self.append_dirname);
}

/// Resolve the effective settings without changing them or the working directory.
/// The caller owns the returned path and must keep it alive while in use.
pub fn resolveSnapshotPath(self: Config, allocator: std.mem.Allocator) ![]u8 {
    try self.validatePersistence();
    return std.fs.path.join(allocator, &.{ self.dir, self.dbfilename });
}

/// The caller owns the returned path. Reuse it for the AOF backend lifetime.
pub fn resolveAofDirectory(self: Config, allocator: std.mem.Allocator) ![]u8 {
    try self.validatePersistence();
    return std.fs.path.join(allocator, &.{ self.dir, self.append_dirname });
}
