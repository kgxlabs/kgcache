const std = @import("std");
const Interface = @import("interface.zig");
const Request = @import("../request.zig");
const resp = @import("../../resp.zig");
const command_arguments = @import("../arguments.zig");
const KGHelpers = @import("../../helpers.zig");
const time = @import("../../time.zig");

pub const Options = std.StaticStringMap(*const Interface.OptionDefinition).initComptime(.{
    .{ "NX", &nx_def },
    .{ "XX", &xx_def },
    .{ "EX", &ex_def },
    .{ "PX", &px_def },
    .{ "EXAT", &exat_def },
    .{ "PXAT", &pxat_def },
    .{ "KEEPTTL", &keepttl_def },
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

const ex_def = Interface.OptionDefinition{
    .keyword = "EX",
    .arity = 1,
    .group = .expiration,
    .repeatable = false,
};
const px_def = Interface.OptionDefinition{
    .keyword = "PX",
    .arity = 1,
    .group = .expiration,
    .repeatable = false,
};
const exat_def = Interface.OptionDefinition{
    .keyword = "EXAT",
    .arity = 1,
    .group = .expiration,
    .repeatable = false,
};
const pxat_def = Interface.OptionDefinition{
    .keyword = "PXAT",
    .arity = 1,
    .group = .expiration,
    .repeatable = false,
};
const keepttl_def = Interface.OptionDefinition{
    .keyword = "KEEPTTL",
    .arity = 0,
    .group = .expiration,
    .repeatable = false,
};

const get_def = Interface.OptionDefinition{
    .keyword = "GET",
    .arity = 0,
    .group = .response,
    .repeatable = false,
};

pub fn apply(req: *Request.SetRequest, def: *const Interface.OptionDefinition, args: []const resp.RESPValue, now_ms: time.UnixMs) !usize {
    if (KGHelpers.eqlStringIgnoreCase(def.keyword, nx_def.keyword)) {
        req.condition = .nx;
        return 1;
    }

    if (KGHelpers.eqlStringIgnoreCase(def.keyword, xx_def.keyword)) {
        req.condition = .xx;
        return 1;
    }

    if (KGHelpers.eqlStringIgnoreCase(def.keyword, ex_def.keyword)) {
        req.expires_at = try relativeExpiration(args, now_ms, std.time.ms_per_s);
        return 2;
    }

    if (KGHelpers.eqlStringIgnoreCase(def.keyword, px_def.keyword)) {
        req.expires_at = try relativeExpiration(args, now_ms, 1);
        return 2;
    }

    if (KGHelpers.eqlStringIgnoreCase(def.keyword, exat_def.keyword)) {
        req.expires_at = try absoluteExpiration(args, std.time.ms_per_s);
        return 2;
    }

    if (KGHelpers.eqlStringIgnoreCase(def.keyword, pxat_def.keyword)) {
        req.expires_at = try absoluteExpiration(args, 1);
        return 2;
    }

    if (KGHelpers.eqlStringIgnoreCase(def.keyword, keepttl_def.keyword)) {
        req.keepttl = true;
        return 1;
    }

    if (KGHelpers.eqlStringIgnoreCase(def.keyword, get_def.keyword)) {
        if (req.response == null) {
            req.response = Request.SetResponse{
                .get = false,
            };
        }

        req.response.?.get = true;
        return 1;
    }

    unreachable;
}

fn relativeExpiration(args: []const resp.RESPValue, now_ms: time.UnixMs, multiplier: i64) !time.UnixMs {
    const value = try expirationArgument(args);
    if (value <= 0) return error.Syntax;

    const duration_ms = std.math.mul(i64, value, multiplier) catch return error.Syntax;
    return std.math.add(i64, now_ms, duration_ms) catch error.Syntax;
}

fn absoluteExpiration(args: []const resp.RESPValue, multiplier: i64) !time.UnixMs {
    const value = try expirationArgument(args);
    if (value <= 0) return error.Syntax;

    return std.math.mul(i64, value, multiplier) catch error.Syntax;
}

fn expirationArgument(args: []const resp.RESPValue) !i64 {
    if (args.len < 2) return error.Syntax;
    return std.fmt.parseInt(i64, try command_arguments.bulkString(args[1]), 10);
}

test "EX is normalized to an absolute millisecond timestamp" {
    var req = emptySetRequest();
    var args = [_]resp.RESPValue{
        .{ .bulk_string = "EX" },
        .{ .bulk_string = "2" },
    };

    _ = try apply(&req, &ex_def, &args, 1_000);
    try std.testing.expectEqual(@as(?time.UnixMs, 3_000), req.expires_at);
}

test "PX is normalized to an absolute millisecond timestamp" {
    var req = emptySetRequest();
    var args = [_]resp.RESPValue{
        .{ .bulk_string = "PX" },
        .{ .bulk_string = "25" },
    };

    _ = try apply(&req, &px_def, &args, 1_000);
    try std.testing.expectEqual(@as(?time.UnixMs, 1_025), req.expires_at);
}

fn emptySetRequest() Request.SetRequest {
    return .{
        .key = "",
        .value = "",
        .condition = null,
        .expires_at = null,
        .keepttl = false,
        .response = null,
    };
}
