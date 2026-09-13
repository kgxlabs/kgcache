const std = @import("std");
const Config = @import("config.zig");
const Server = @import("server.zig");
const logging = @import("logger.zig");

pub fn main(init: std.process.Init) !void {
    var default_logger = logging.DefaultLogger.init(init.io);
    const logger = default_logger.logger();

    const config = try Config.loadFromArgs(init);

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    const server = try Server.create(init.io, gpa.allocator(), config, logger);
    defer server.destroy();

    // TODO: install SIGINT/SIGTERM shutdown handling after acceptLoop can be
    // woken and active connection threads can be drained safely.
    try server.run();
}
