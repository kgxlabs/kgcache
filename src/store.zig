pub const Store = @import("store/store.zig");
pub const MemoryStore = @import("store/mem_store.zig");

pub fn errorToString(err: Store.Error) []const u8 {
    return switch (err) {
        else => "Something went wrong",
    };
}
