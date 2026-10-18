pub const Backend = enum(u8) { kgc, aof };
pub const Stage = enum(u8) { before_write, synced, draining, reaped };

// One raw pipe write keeps records from the server and child together.
pub const Event = extern struct {
    server_pid: i32,
    child_pid: i32,
    operation: u32,
    status: u32 = 0,
    backend: Backend,
    stage: Stage,
    reserved: [2]u8 = .{ 0, 0 },
};
