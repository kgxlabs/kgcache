pub const SetRequest = struct {
    key: []const u8,
    value: []const u8,
    condition: ?SetCondition,
    expiration: ?SetExpiration,
    // NOTE: may be when redis adds more response related options, we will make this SetResponse tagged union as well
    // But for now, this is enough
    get: bool = false,
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
