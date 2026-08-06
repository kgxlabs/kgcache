const Store = @import("interface.zig");
const object = @import("../object.zig");
const Request = @import("../commander/request.zig");

const MockStore = @This();

get_result: Store.Error!?object.Object = null,
set_result: Store.Error!?object.Object = null,
dbsize_result: u32 = 0,
num_databases_result: u32 = 1,
get_calls: usize = 0,
set_calls: usize = 0,
dbsize_calls: usize = 0,
save_calls: usize = 0,
last_get_key: ?[]const u8 = null,
last_set_key: ?[]const u8 = null,
last_set_value: ?[]const u8 = null,

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
    .dbsize = dbsize,
    .numDatabases = numDatabases,
    .save = save,
    .deinit = deinit,
};

fn get(ptr: *anyopaque, key: []const u8, _: u32) Store.Error!?object.Object {
    const self: *MockStore = @ptrCast(@alignCast(ptr));
    self.get_calls += 1;
    self.last_get_key = key;
    return self.get_result;
}

fn set(ptr: *anyopaque, req: Request.SetRequest, _: u32) Store.Error!?object.Object {
    const self: *MockStore = @ptrCast(@alignCast(ptr));
    self.set_calls += 1;
    self.last_set_key = req.key;
    self.last_set_value = req.value;
    return self.set_result;
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

fn save(ptr: *anyopaque) Store.Error!void {
    const self: *MockStore = @ptrCast(@alignCast(ptr));
    self.save_calls += 1;
}

fn deinit(_: *anyopaque) void {}
