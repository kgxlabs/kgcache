const std = @import("std");
const resp = @import("../resp.zig");
const store = @import("../store.zig");
const command_arguments = @import("arguments.zig");
const Commander = @import("interface.zig");

const Command = @This();

const Subcommand = enum {
    count,
    list,
    info,
    getkeys,
    getkeysandflags,
};

allocator: std.mem.Allocator,
arguments: []resp.RESPValue,

pub fn commander(self: *Command) Commander {
    return .{ .ptr = self, .vtable = &vtable };
}

const vtable = Commander.VTable{ .execute = execute, .deinit = deinit };

fn execute(ptr: *anyopaque, _: std.Io, _: *store.Store, _: *Commander.ClientState) Commander.Error!Commander.Result {
    const self: *Command = @ptrCast(@alignCast(ptr));
    if (self.arguments.len == 0) return self.executeAll();

    const name = try command_arguments.bulkString(self.arguments[0]);

    return self.executeSubcommand(try parseSubcommand(name));
}

fn parseSubcommand(name: []const u8) Commander.Error!Subcommand {
    if (std.ascii.eqlIgnoreCase(name, "COUNT")) return .count;
    if (std.ascii.eqlIgnoreCase(name, "LIST")) return .list;
    if (std.ascii.eqlIgnoreCase(name, "INFO")) return .info;
    if (std.ascii.eqlIgnoreCase(name, "GETKEYS")) return .getkeys;
    if (std.ascii.eqlIgnoreCase(name, "GETKEYSANDFLAGS")) return .getkeysandflags;
    return error.UnsupportedOption;
}

fn executeSubcommand(self: *Command, subcommand: Subcommand) Commander.Error!Commander.Result {
    return switch (subcommand) {
        .count => self.executeCount(),
        .list => self.executeList(),
        .info => self.executeInfo(),
        .getkeys => self.executeGetKeys(),
        .getkeysandflags => self.executeGetKeysAndFlags(),
    };
}

fn executeAll(_: *Command) Commander.Error!Commander.Result {
    return error.UnsupportedOption;
}

fn executeCount(_: *Command) Commander.Error!Commander.Result {
    return error.UnsupportedOption;
}

fn executeList(_: *Command) Commander.Error!Commander.Result {
    return error.UnsupportedOption;
}

fn executeInfo(_: *Command) Commander.Error!Commander.Result {
    return error.UnsupportedOption;
}

fn executeGetKeys(_: *Command) Commander.Error!Commander.Result {
    return error.UnsupportedOption;
}

fn executeGetKeysAndFlags(_: *Command) Commander.Error!Commander.Result {
    return error.UnsupportedOption;
}

fn deinit(ptr: *anyopaque) void {
    const self: *Command = @ptrCast(@alignCast(ptr));
    self.allocator.destroy(self);
}
