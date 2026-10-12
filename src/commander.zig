const std = @import("std");
const CommandFrame = @import("protocol/command_frame.zig");
const registry = @import("commander/registry.zig");
pub const Commander = @import("commander/interface.zig");
pub const Error = Commander.Error;

pub fn init(allocator: std.mem.Allocator, frame: CommandFrame) Error!Commander {
    const definition = try registry.resolve(frame);

    var command = try definition.factory.?(allocator, frame.arguments);

    command.canonical_name = definition.name;

    return command;
}
