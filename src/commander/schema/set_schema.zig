const std = @import("std");
const Interface = @import("interface.zig");
const Request = @import("../request.zig");
const KGHelpers = @import("../../helpers.zig");

pub const Options = std.StaticStringMap(*const Interface.OptionDefinition).initComptime(.{
    .{ "NX", &nx_def },
    .{ "XX", &xx_def },
    .{ "GET", &get_def },
});

const nx_def = Interface.OptionDefinition{
    .keyword = "NX",
    .arity = 0,
    .group = .condition,
    .repeatable = false,
};

const xx_def = Interface.OptionDefinition{
    .keyword = "XX",
    .arity = 0,
    .group = .condition,
    .repeatable = false,
};

const get_def = Interface.OptionDefinition{
    .keyword = "GET",
    .arity = 0,
    .group = .response,
};

pub fn apply(req: *Request.SetRequest, def: *const Interface.OptionDefinition, _: []const []const u8) !void {
    if (KGHelpers.eqlStringIgnoreCase(def.*.keyword, nx_def.keyword)) {
        req.condition = .nx;
        return;
    }

    if (KGHelpers.eqlStringIgnoreCase(def.*.keyword, xx_def.keyword)) {
        req.condition = .xx;
        return;
    }

    if (KGHelpers.eqlStringIgnoreCase(def.*.keyword, get_def.keyword)) {
        req.get = true;
        return;
    }

    unreachable;
}
