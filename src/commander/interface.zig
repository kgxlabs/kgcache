const resp = @import("../resp.zig");
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
    value: resp.RESPValue,
    owned_object: ?object.Owned = null,
    owned_arena: ?*std.heap.ArenaAllocator = null,

    pub fn borrowed(value: resp.RESPValue) Result {
        return .{ .value = value };
    }

    pub fn owned(owned_value: object.Owned) !Result {
        var object_value = owned_value;
        errdefer object_value.deinit();

        return .{
            .value = try object.toRESP(object_value.value),
            .owned_object = object_value,
        };
    }

    pub fn inArena(value: resp.RESPValue, arena: *std.heap.ArenaAllocator) Result {
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
