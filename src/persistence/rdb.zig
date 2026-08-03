const std = @import("std");
const Persistence = @import("./interface.zig");

const RdbBackend = @This();

const vtable: Persistence.VTable = .{
    .onWrite = onWrite,
};

pub fn init() RdbBackend {
    return .{};
}

pub fn persistence(self: *RdbBackend) Persistence {
    return .{
        .ptr = self,
        .vtable = &vtable,
    };
}

pub fn onWrite(_: *anyopaque, _: Persistence.WriteEvent) Persistence.Error!void {
    return;
}
