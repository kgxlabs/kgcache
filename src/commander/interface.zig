const Reply = @import("../protocol/reply.zig").Reply;
const store = @import("../store.zig");
const std = @import("std");
const object = @import("../object.zig");

pub const ClientState = @import("../client_state.zig");

const Commander = @This();

pub const Error = std.mem.Allocator.Error || error{
    UnknownCommand,
    UnsupportedKeyword,
    UnsupportedArgumentType,
    MalformedCommandRequest,
    WrongNumberArguments,
    UnsupportedOption,
    Syntax,
    DbIndexOutOfRange,
};

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    execute: *const fn (*anyopaque, std.Io, *store.Store, *ClientState) anyerror!Result,
    deinit: *const fn (*anyopaque) void,
};

pub const Result = struct {
    value: Reply,
    owned_object: ?object.Owned = null,
    owned_arena: ?*std.heap.ArenaAllocator = null,

    pub fn borrowed(value: Reply) Result {
        return .{ .value = value };
    }

    pub fn owned(owned_value: object.Owned) !Result {
        return .{
            .value = switch (owned_value.value) {
                .string => |bytes| .{ .blob_string = bytes },
            },
            .owned_object = owned_value,
        };
    }

    pub fn inArena(value: Reply, arena: *std.heap.ArenaAllocator) Result {
        return .{ .value = value, .owned_arena = arena };
    }

    pub fn deinit(self: *Result) void {
        if (self.owned_object) |*owned_value| owned_value.deinit();
        if (self.owned_arena) |arena| {
            const allocator = arena.child_allocator;
            arena.deinit();
            allocator.destroy(arena);
        }
        self.* = undefined;
    }
};

pub fn execute(self: Commander, io: std.Io, data_store: *store.Store, client_state: *ClientState) anyerror!Result {
    return self.vtable.execute(self.ptr, io, data_store, client_state);
}

pub fn deinit(self: Commander) void {
    self.vtable.deinit(self.ptr);
}
