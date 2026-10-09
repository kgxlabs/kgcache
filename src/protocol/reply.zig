pub const Resp2NullKind = enum { bulk_string, array };

pub const MapEntry = struct {
    key: Reply,
    value: Reply,
};

pub const Reply = union(enum) {
    null_value: Resp2NullKind,
    simple_string: []const u8,
    error_reply: []const u8,
    integer: i64,
    blob_string: []const u8,
    array: []const Reply,
    map: []const MapEntry,
};
