const std = @import("std");
const Config = @import("../config.zig");
const directive_definition = @import("definition.zig");
const DirectiveDefinition = directive_definition.Definition;

const ConfigBuilder = @This();

pub const Layer = enum {
    file,
    cli,
};

const StateEntry = struct {
    definition: *const DirectiveDefinition,
    state: *anyopaque,
    applied_in_cli: bool = false,
};

const Status = enum {
    building,
    failed,
    finished,
};

allocator: std.mem.Allocator,
config: Config,
states: std.ArrayList(StateEntry) = .empty,
status: Status = .building,

pub fn init(allocator: std.mem.Allocator) ConfigBuilder {
    return .{
        .allocator = allocator,
        .config = Config.default(),
    };
}

pub fn apply(
    self: *ConfigBuilder,
    directive: directive_definition.PreparedDirective,
    layer: Layer,
) directive_definition.ApplyError!void {
    _ = self;
    _ = directive;
    _ = layer;
    @panic("config builder application is not implemented");
}

pub fn finish(self: *ConfigBuilder) directive_definition.BuildError!Config {
    _ = self;
    @panic("config builder finish is not implemented");
}

pub fn deinit(self: *ConfigBuilder) void {
    const mode: directive_definition.CleanupMode = if (self.status == .finished) .retain_config else .discard;
    for (self.states.items) |entry| {
        var context: directive_definition.ApplyContext = .{
            .allocator = self.allocator,
            .config = &self.config,
            .state = entry.state,
        };
        entry.definition.state_lifecycle.?.deinit(&context, mode);
    }
    self.states.deinit(self.allocator);
    self.* = undefined;
}

test {
    std.testing.refAllDecls(@This());
    _ = @sizeOf(ConfigBuilder);
}
