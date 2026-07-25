pub const SetRequest = struct {
    key: []const u8,
    value: []const u8,
    condition: ?SetCondition,
    expiration: ?SetExpiration,
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

pub const SetExpiration = union(enum) {
    ex: u64,
    px: u64,
    exat: u64,
    pxat: u64,
    // we don't need any value since we are goona keep the existing TTL
    keepttl: void,
};

pub const SetResponse = union(enum) {
    get: bool,
};
