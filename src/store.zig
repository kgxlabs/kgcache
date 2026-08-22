pub const Store = @import("store/interface.zig");
pub const MemoryStore = @import("store/mem_store.zig");
pub const MockStore = @import("store/mock_store.zig");

pub fn errorToString(err: Store.Error) []const u8 {
    return switch (err) {
        error.UnsupportedCondition => "Unsupported condition",
        error.OutOfMemory => "Out of memory",
        error.CancelledCommand => "Command cancelled",
        error.SomethingWentWrong => "Something went wrong",
        error.UnableToSave => "Unable to save",
        error.UnableToDoBackgroundSave => "Unable to do background save",
    };
}
