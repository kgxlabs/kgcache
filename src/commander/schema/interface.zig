pub const OptionGroup = enum {
    condition,
    expiration,
    response,
};

pub const OptionDefinition = struct {
    keyword: []const u8,
    arity: i8,
    group: OptionGroup,
    repeatable: bool,
};
