const std = @import("std");

const Config = @This();

pub const SaveRule = struct {
    seconds: i64,
    changes: u32,
};

pub const AppendFsync = enum { always, everysec, no };

bind_address: []const u8 = "127.0.0.1",
port: u16 = 6379,
reuse_address: bool = true,
connection_buffer_size: usize = 1024,
num_databases: usize = 16,
// Shared persistence directory, resolved from the process working directory.
dir: []const u8 = ".",
dbfilename: []const u8 = "dump.kgc",
cron_interval_ms: i64 = 100,
active_expire_budget_ms: i8 = 10,
active_expire_batch_size: i8 = 20,
active_expire_threshold_percent: i8 = 25,
exclusive_bg_persistence: bool = true,
// Empty rules disable automatic saving; CLI rules replace file rules.
save_rules: []const SaveRule = &.{},
append_only: bool = false,
// Base name for AOF parts and their manifest.
append_filename: []const u8 = "appendonly.aof",
// kgcache owns and cleans this directory within dir.
append_dirname: []const u8 = "appendonlydir",
append_fsync: AppendFsync = .everysec,
// Zero disables automatic rewrites; BGREWRITEAOF still works.
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

// Caller owns the returned path.
pub fn resolveSnapshotPath(self: Config, allocator: std.mem.Allocator) ![]u8 {
    try self.validatePersistence();
    return std.fs.path.join(allocator, &.{ self.dir, self.dbfilename });
}

// Caller owns the returned path.
pub fn resolveAofDirectory(self: Config, allocator: std.mem.Allocator) ![]u8 {
    try self.validatePersistence();
    return std.fs.path.join(allocator, &.{ self.dir, self.append_dirname });
}
