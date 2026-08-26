const std = @import("std");
const ConfigParser = @import("config_parser.zig");

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
snapshot_path: []const u8 = "dump.kgc",
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
/// Directory holding all AOF files, resolved against the process's cwd.
/// kgcache owns this directory entirely: an interrupted rewrite can leave
/// orphan files behind, and cleaning those up is only safe if nothing else
/// shares the directory.
append_dirname: []const u8 = "appendonlydir",
append_fsync: AppendFsync = .everysec,
/// `auto-aof-rewrite-percentage 0` means never rewrite automatically; but BGREWRITEAOF by hand still works.
auto_aof_rewrite_percentage: u32 = 100,
auto_aof_rewrite_min_size: usize = 67108864,
aof_load_truncated: bool = true,

pub fn default() Config {
    return .{};
}

/// Reads the config file path from the first positional CLI argument, if
/// any (`kgcache [path/to/kgcache.conf]`); with no argument, returns
/// `Config.default()`.
/// A path that can't be read or doesn't parse fails the process fast, with a message on stderr,
/// rather than silently falling back to defaults.
pub fn loadFromArgs(init: std.process.Init) !Config {
    // NOTE: Using arena allocator instead of gpa
    // We are not copying the parsed bytes. Instead, we are pointing to the raw file bytes we read
    // And we need those as long as the server lives , meaning we do not need to free them one by one
    // with gpa, this will be flagged as a memory leak bug.
    // with arena allocator, we can free when server dies.
    const allocator = init.arena.allocator();

    var args = init.minimal.args.iterate();
    _ = args.skip(); // program name

    const conf_path = args.next() orelse return Config.default();

    const contents = std.Io.Dir.cwd().readFileAlloc(init.io, conf_path, allocator, .unlimited) catch |err| {
        try reportConfigError(init.io, allocator, "failed to read config file '{s}': {s}", .{ conf_path, @errorName(err) });
        return err;
    };

    return ConfigParser.parse(allocator, contents) catch |err| {
        try reportConfigError(init.io, allocator, "invalid config file '{s}': {s}", .{ conf_path, @errorName(err) });
        return err;
    };
}

fn reportConfigError(io: std.Io, allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const message = try std.fmt.allocPrint(allocator, "kgcache: " ++ fmt ++ "\n", args);
    try std.Io.File.writeStreamingAll(std.Io.File.stderr(), io, message);
}
