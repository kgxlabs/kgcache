const std = @import("std");
const Store = @import("interface.zig");
const Storage = @import("../storage/interface.zig");
const DefaultStorage = @import("../storage/default_storage.zig");
const object = @import("../object.zig");
const Request = @import("../commander/request.zig");
const testing = std.testing;

const MemoryStore = @This();

_storage: Storage,
/// Takes ownership of `storage`: `deinit` calls `Storage.deinit` on it.
pub fn init(storage: Storage) MemoryStore {
    return .{
        ._storage = storage,
    };
}

pub fn deinit(ptr: *anyopaque) void {
    const self: *MemoryStore = @ptrCast(@alignCast(ptr));
    self._storage.deinit();
}

pub fn store(self: *MemoryStore) Store {
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
    const self: *MemoryStore = @ptrCast(@alignCast(ptr));

    // TODO: Refactor with robust error propagation design
    const maybe_value = self._storage.get(key) catch return Store.Error.SomethingWentWrong;
    const value = maybe_value orelse return null;
    return value.value;
}

// TODO: Support all of these options
// SET key value [NX | XX | IFEQ ifeq-value | IFNE ifne-value |
// IFDEQ ifdeq-digest | IFDNE ifdne-digest] [GET] [EX seconds |
// PX milliseconds | EXAT unix-time-seconds |
// PXAT unix-time-milliseconds | KEEPTTL]
fn set(ptr: *anyopaque, req: Request.SetRequest) Store.Error!?object.Object {
    const self: *MemoryStore = @ptrCast(@alignCast(ptr));
    try validateCondition(req.condition);

    // TODO: Refactor with robust error propagation design
    const existing_entry = self._storage.get(req.key) catch return Store.Error.SomethingWentWrong;
    if (existing_entry != null and shouldSkipIfExist(req.condition)) {
        return makeSetResponse(req, existing_entry.?.value);
    }

    if (existing_entry == null and shouldSkipIfNotExist(req.condition)) {
        return makeSetResponse(req, null);
    }

    // TODO: Refactor with robust error propagation design
    const stored_entry = self._storage.put(req.key, .{
        .string = req.value,
    }, .{
        .expires_at = req.expires_at,
        .keepttl = req.keepttl,
    }) catch return Store.Error.SomethingWentWrong;

    return makeSetResponse(req, stored_entry.value);
}

fn shouldSkipIfExist(maybe_condition: ?Request.SetCondition) bool {
    if (maybe_condition) |condition| {
        return switch (condition) {
            .nx => true,
            .xx => false,
            else => false,
        };
    }
    return false;
}

fn shouldSkipIfNotExist(maybe_condition: ?Request.SetCondition) bool {
    if (maybe_condition) |condition| {
        return switch (condition) {
            .nx => false,
            .xx => true,
            else => false,
        };
    }
    return false;
}

fn validateCondition(maybe_condition: ?Request.SetCondition) Store.Error!void {
    if (maybe_condition) |condition| switch (condition) {
        .nx, .xx => {},
        else => return error.UnsupportedCondition,
    };
}

fn makeSetResponse(req: Request.SetRequest, value: ?object.Object) ?object.Object {
    if (req.response != null and req.response.?.get) {
        return value;
    }

    return null;
}

test "set stores a value and returns null" {
    var backend = DefaultStorage.init(testing.allocator);
    var memory_store = MemoryStore.init(backend.storage());
    var data_store = memory_store.store();

    defer data_store.deinit();

    const req: Request.SetRequest = .{
        .key = "foo",
        .value = "barz",
        .condition = null,
        .expires_at = null,
        .keepttl = false,
        .response = null,
    };
    const set_value = try data_store.set(testing.io, req);

    try testing.expect(set_value == null);

    const get_value = try data_store.get(testing.io, req.key) orelse return error.TestUnexpectedResult;
    try expectObjectString(get_value, req.value);
}

test "set stores a value and returns value" {
    var backend = DefaultStorage.init(testing.allocator);
    var memory_store = MemoryStore.init(backend.storage());
    var data_store = memory_store.store();
    defer data_store.deinit();

    const req: Request.SetRequest = .{
        .key = "foo",
        .value = "barz",
        .condition = null,
        .expires_at = null,
        .keepttl = false,
        .response = .{ .get = true },
    };

    const set_value = try data_store.set(testing.io, req);

    try expectObjectString(set_value, req.value);

    const get_value = try data_store.get(testing.io, req.key) orelse return error.TestUnexpectedResult;
    try expectObjectString(get_value, req.value);
}

test "get returns null for a missing key" {
    var backend = DefaultStorage.init(testing.allocator);
    var memory_store = MemoryStore.init(backend.storage());
    var data_store = memory_store.store();
    defer data_store.deinit();

    const value = try data_store.get(testing.io, "missing");

    try testing.expect(value == null);
}

test "set replaces an existing value" {
    var backend = DefaultStorage.init(testing.allocator);
    var memory_store = MemoryStore.init(backend.storage());
    var data_store = memory_store.store();
    defer data_store.deinit();

    const first_req: Request.SetRequest = .{
        .key = "key",
        .value = "first",
        .condition = null,
        .expires_at = null,
        .keepttl = false,
        .response = null,
    };
    _ = try data_store.set(testing.io, first_req);

    const second_req: Request.SetRequest = .{
        .key = "key",
        .value = "second",
        .condition = null,
        .expires_at = null,
        .keepttl = false,
        .response = null,
    };

    const result = try data_store.set(testing.io, second_req);

    try testing.expect(result == null);

    const value = try data_store.get(testing.io, "key") orelse return error.TestUnexpectedResult;
    try expectObjectString(value, "second");
}

test "set with NX does not replace an existing value" {
    var backend = DefaultStorage.init(testing.allocator);
    var memory_store = MemoryStore.init(backend.storage());
    var data_store = memory_store.store();
    defer data_store.deinit();

    _ = try data_store.set(testing.io, .{
        .key = "key",
        .value = "first",
        .condition = null,
        .expires_at = null,
        .keepttl = false,
        .response = null,
    });
    _ = try data_store.set(testing.io, .{
        .key = "key",
        .value = "second",
        .condition = .nx,
        .expires_at = null,
        .keepttl = false,
        .response = null,
    });

    const value = try data_store.get(testing.io, "key") orelse return error.TestUnexpectedResult;
    try expectObjectString(value, "first");
}

test "set with XX does not create a missing value" {
    var backend = DefaultStorage.init(testing.allocator);
    var memory_store = MemoryStore.init(backend.storage());
    var data_store = memory_store.store();
    defer data_store.deinit();

    _ = try data_store.set(testing.io, .{
        .key = "missing",
        .value = "value",
        .condition = .xx,
        .expires_at = null,
        .keepttl = false,
        .response = null,
    });

    try testing.expect(try data_store.get(testing.io, "missing") == null);
}

test "set owns the key and value bytes" {
    var backend = DefaultStorage.init(testing.allocator);
    var memory_store = MemoryStore.init(backend.storage());
    var data_store = memory_store.store();
    defer data_store.deinit();

    var key = [_]u8{ 'k', 'e', 'y' };
    var value = [_]u8{ 'o', 'n', 'e' };

    const req: Request.SetRequest = .{
        .key = &key,
        .value = &value,
        .condition = null,
        .expires_at = null,
        .keepttl = false,
        .response = null,
    };
    _ = try data_store.set(testing.io, req);

    @memset(&key, 'x');
    @memset(&value, 'x');

    const stored_value = try data_store.get(testing.io, "key") orelse return error.TestUnexpectedResult;
    try expectObjectString(stored_value, "one");
}

fn expectObjectString(maybe_value: ?object.Object, expected: []const u8) !void {
    const value = maybe_value orelse return error.Null;

    switch (value) {
        .string => |str| {
            try testing.expectEqualStrings(expected, str);
        },
    }
}
