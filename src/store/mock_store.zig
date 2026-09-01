const Store = @import("interface.zig");
const object = @import("../object.zig");
const Request = @import("../commander/request.zig");

const MockStore = @This();

get_result: Store.Error!?object.Object = null,
set_result: Store.Error!?object.Object = null,
remove_result: Store.Error!bool = false,
dbsize_result: u32 = 0,
num_databases_result: u32 = 1,
get_calls: usize = 0,
set_calls: usize = 0,
remove_calls: usize = 0,
dbsize_calls: usize = 0,
save_calls: usize = 0,
bgsave_calls: usize = 0,
bgrewriteaof_calls: usize = 0,
last_get_key: ?[]const u8 = null,
last_set_key: ?[]const u8 = null,
last_set_value: ?[]const u8 = null,
last_set_value_copy: [256]u8 = @splat(0),
last_set_value_len: usize = 0,
last_set_db: ?u32 = null,
last_remove_key: ?[]const u8 = null,

pub fn init() MockStore {
    return .{};
}

pub fn store(self: *MockStore) Store {
    return .{
        .ptr = self,
        .vtable = &vtable,
    };
}

const vtable = Store.VTable{
    .get = get,
    .set = set,
    .remove = remove,
    .dbsize = dbsize,
    .numDatabases = numDatabases,
    .save = save,
    .bgsave = bgsave,
    .bgrewriteaof = bgrewriteaof,
    .deinit = deinit,
};

fn get(ptr: *anyopaque, key: []const u8, _: u32) Store.Error!?object.Object {
    const self: *MockStore = @ptrCast(@alignCast(ptr));
    self.get_calls += 1;
    self.last_get_key = key;
    return self.get_result;
}

fn set(ptr: *anyopaque, req: Request.SetRequest, db_index: u32) Store.Error!?object.Object {
    const self: *MockStore = @ptrCast(@alignCast(ptr));
    self.set_calls += 1;
    self.last_set_key = req.key;
    self.last_set_value = req.value;
    if (req.value.len <= self.last_set_value_copy.len) {
        @memcpy(self.last_set_value_copy[0..req.value.len], req.value);
        self.last_set_value_len = req.value.len;
    }
    self.last_set_db = db_index;
    return self.set_result;
}

fn remove(ptr: *anyopaque, key: []const u8, _: u32) Store.Error!bool {
    const self: *MockStore = @ptrCast(@alignCast(ptr));
    self.remove_calls += 1;
    self.last_remove_key = key;
    return self.remove_result;
}

fn dbsize(ptr: *anyopaque, _: u32) u32 {
    const self: *MockStore = @ptrCast(@alignCast(ptr));
    self.dbsize_calls += 1;
    return self.dbsize_result;
}

fn numDatabases(ptr: *anyopaque) u32 {
    const self: *MockStore = @ptrCast(@alignCast(ptr));
    return self.num_databases_result;
}

fn save(ptr: *anyopaque, _: i64) Store.Error!void {
    const self: *MockStore = @ptrCast(@alignCast(ptr));
    self.save_calls += 1;
}

fn bgsave(ptr: *anyopaque) Store.Error!void {
    const self: *MockStore = @ptrCast(@alignCast(ptr));
    self.bgsave_calls += 1;
}

fn bgrewriteaof(ptr: *anyopaque) Store.Error!void {
    const self: *MockStore = @ptrCast(@alignCast(ptr));
    self.bgrewriteaof_calls += 1;
}

fn deinit(_: *anyopaque) void {}
