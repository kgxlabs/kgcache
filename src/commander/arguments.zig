const resp = @import("../resp.zig");
const Commander = @import("interface.zig");

pub fn bulkString(argument: resp.RESPValue) Commander.Error![]const u8 {
    return switch (argument) {
        .bulk_string => |maybe_string| maybe_string orelse Commander.Error.MalformedCommandRequest,
        else => Commander.Error.UnsupportedArgumentType,
    };
}
