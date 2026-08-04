const std = @import("std");
const Journal = @import("./journal_interface.zig");

const AofBackend = @This();

const vtable: Journal.VTable = .{
    .onWrite = onWrite,
};

pub fn init() AofBackend {
    return .{};
}

pub fn journal(self: *AofBackend) Journal {
    return .{
        .ptr = self,
        .vtable = &vtable,
    };
}

pub fn onWrite(_: *anyopaque, _: Journal.WriteEvent) Journal.Error!void {
    return;
}
