const resp = @import("../resp.zig");
const Commander = @import("interface.zig");

pub fn bulkString(argument: resp.RESPValue) Commander.Error![]const u8 {
    return switch (argument) {
        .bulk_string => |maybe_string| maybe_string orelse Commander.Error.MalformedCommandRequest,
        else => Commander.Error.UnsupportedArgumentType,
    };
}

pub fn integer(argument: resp.RESPValue) Commander.Error!u32 {
    return switch (argument) {
        .integer => |maybe_int| maybe_int orelse Commander.Error.MalformedCommandRequest,
        else => Commander.Error.UnsupportedArgumentType,
    };
}
