const time = @import("../time.zig");

pub const SetRequest = struct {
    key: []const u8,
    value: []const u8,
    condition: ?SetCondition,
    expires_at: ?time.UnixMs,
    keepttl: bool,
    // NOTE: This could be overkill since for `SET` command we will only ever get `GET` response option
    // I am doing this way for purely consistency
    // TODO: Refactor if I find a better alternative
    response: ?SetResponse,
};

pub const SetCondition = union(enum) {
    nx,
    xx,
    ifeq: []const u8,
    ifne: []const u8,
    ifdeq: []const u8,
    ifdne: []const u8,
};

pub const SetResponse = union(enum) {
    get: bool,
};
