const Config = @This();

bind_address: []const u8 = "127.0.0.1",
port: u16 = 6379,
reuse_address: bool = true,
connection_buffer_size: usize = 1024,
num_databases: usize = 16,
snapshot_path: []const u8 = "dump.kgc",
active_expire_interval_ms: i64 = 100,
active_expire_budget_ms: i8 = 10,
active_expire_batch_size: i8 = 20,
active_expire_threshold_percent: i8 = 25,
exclusive_bg_persistence: bool = false,

pub fn default() Config {
    return .{};
}
