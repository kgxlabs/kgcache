const std = @import("std");
const CommandFrame = @import("protocol/command_frame.zig");
const registry = @import("commander/registry.zig");
pub const Commander = @import("commander/interface.zig");
pub const Error = Commander.Error;

pub fn init(allocator: std.mem.Allocator, frame: CommandFrame) Error!Commander {
    const definition = registry.find(frame.name) orelse return error.UnknownCommand;
    if (!definition.arity.accepts(frame.arguments.len)) return error.WrongNumberArguments;

    var command = try definition.factory(allocator, frame.arguments);
    if (command.canonical_name.len == 0) command.canonical_name = definition.name;

    return command;
}
