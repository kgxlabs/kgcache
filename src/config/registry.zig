const std = @import("std");
const directive_definition = @import("definition.zig");
const DirectiveDefinition = directive_definition.Definition;

pub fn find(name: []const u8) ?*const DirectiveDefinition {
    _ = name;
    @panic("config registry lookup is not implemented");
}

pub fn all() []const DirectiveDefinition {
    @panic("config registry definitions are not implemented");
}

pub fn prepare(
    definition: *const DirectiveDefinition,
    values: []const []const u8,
) directive_definition.ParseError!directive_definition.PreparedDirective {
    _ = definition;
    _ = values;
    @panic("config directive preparation is not implemented");
}

test {
    std.testing.refAllDecls(@This());
}
