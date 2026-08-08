const resp = @import("../resp.zig");
const store = @import("../store.zig");
const std = @import("std");

pub const ClientState = @import("../client_state.zig");

const Commander = @This();

pub const Error = std.mem.Allocator.Error || error{
    UnknownCommand,
    UnsupportedKeyword,
    UnsupportedArgumentType,
    MalformedCommandRequest,
    WrongNumberArguments,
    UnableToConvertObject,
    UnsupportedOption,
    Syntax,
    SomethingWentWrong,
    UnableToSaveKgc,
};

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    execute: *const fn (*anyopaque, std.Io, *store.Store, *ClientState) Error!resp.RESPValue,
    deinit: *const fn (*anyopaque) void,
};

pub fn execute(self: Commander, io: std.Io, data_store: *store.Store, client_state: *ClientState) Error!resp.RESPValue {
    return self.vtable.execute(self.ptr, io, data_store, client_state);
}

pub fn deinit(self: Commander) void {
    self.vtable.deinit(self.ptr);
}
