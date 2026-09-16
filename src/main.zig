const std = @import("std");
const Config = @import("config.zig");
const Server = @import("server.zig");
const logging = @import("logger.zig");

pub fn main(init: std.process.Init) u8 {
    // Server borrows this logger. Keep its storage alive for the full Server lifetime.
    var default_logger = logging.DefaultLogger.init(init.io);
    const logger = default_logger.logger();

    // Return 0 for success and 1 for failure so callers can check the result.
    // The lifecycle already logged failures, so do not let Zig report them again.
    runApplication(init, logger) catch return 1;
    return 0;
}

pub fn runApplication(init: std.process.Init, logger: logging.Logger) !void {
    const config = Config.loadFromArgs(init) catch |err| {
        logger.err("app: failed to load configuration", err, @errorReturnTrace());
        return err;
    };

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    const server = Server.create(init.io, gpa.allocator(), config, logger) catch |err| {
        logger.err("app: failed to create server", err, @errorReturnTrace());
        return err;
    };
    defer server.destroy();

    // TODO: install SIGINT/SIGTERM shutdown handling after acceptLoop can be
    // woken and active connection threads can be drained safely.
    server.run() catch |err| {
        logger.err("app: server runtime failed", err, @errorReturnTrace());
        return err;
    };
}
