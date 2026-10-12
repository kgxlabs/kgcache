const std = @import("std");
const connection = @import("../../connection.zig");
const store = @import("../../store.zig");
const Commander = @import("../interface.zig");

const ClientSetinfo = @This();

allocator: std.mem.Allocator,
arguments: []const []const u8,

pub fn init(allocator: std.mem.Allocator, arguments: []const []const u8) Commander.Error!Commander {
    const self = try allocator.create(ClientSetinfo);
    self.* = .{ .allocator = allocator, .arguments = arguments };
    return .{ .ptr = self, .vtable = &vtable };
}

const vtable: Commander.VTable = .{ .execute = execute, .deinit = deinit };

fn execute(ptr: *anyopaque, _: std.Io, _: *store.Store, state: *Commander.ClientState) anyerror!Commander.Result {
    const self: *ClientSetinfo = @ptrCast(@alignCast(ptr));
    const attribute: connection.ConnectionReport.LibraryAttribute = if (std.ascii.eqlIgnoreCase(self.arguments[1], "lib-name"))
        .lib_name
    else if (std.ascii.eqlIgnoreCase(self.arguments[1], "lib-ver"))
        .lib_ver
    else
        return error.UnsupportedOption;

    const value = self.arguments[2];
    for (value) |byte| {
        if (byte < '!' or byte > '~') return error.Syntax;
    }

    const context = state.connection_context orelse return error.MissingConnectionContext;
    try context.setLibraryInfo(attribute, value);
    return Commander.Result.borrowed(.{ .simple_string = "OK" });
}

fn deinit(ptr: *anyopaque) void {
    const self: *ClientSetinfo = @ptrCast(@alignCast(ptr));
    self.allocator.destroy(self);
}
