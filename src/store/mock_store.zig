const Store = @import("interface.zig");
const object = @import("../object.zig");

const MockStore = @This();

get_result: Store.Error!?object.Object = null,
set_result: Store.Error!?object.Object = null,
get_calls: usize = 0,
set_calls: usize = 0,
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
    .deinit = deinit,
};

fn get(ptr: *anyopaque, key: []const u8) Store.Error!?object.Object {
    const self: *MockStore = @ptrCast(@alignCast(ptr));
    self.get_calls += 1;
    self.last_get_key = key;
    return self.get_result;
}

fn set(ptr: *anyopaque, key: []const u8, value: []const u8) Store.Error!?object.Object {
    const self: *MockStore = @ptrCast(@alignCast(ptr));
    self.set_calls += 1;
    self.last_set_key = key;
    self.last_set_value = value;
    return self.set_result;
}

fn deinit(_: *anyopaque) void {}
