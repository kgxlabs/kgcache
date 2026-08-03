const std = @import("std");
const Persistence = @import("./interface.zig");

const AofBackend = @This();

const vtable: Persistence.VTable = .{
    .onWrite = onWrite,
};

pub fn init() AofBackend {
    return .{};
}

pub fn persistence(self: *AofBackend) Persistence {
    return .{
        .ptr = self,
        .vtable = &vtable,
    };
}

pub fn onWrite(_: *anyopaque, _: persistence.WriteEvent) persistence.Error!void {
    return;
}
