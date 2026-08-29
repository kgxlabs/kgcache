test {
    _ = @import("resp.zig");
    _ = @import("commander.zig");
    _ = @import("commander/echo.zig");
    _ = @import("commander/ping.zig");
    _ = @import("store.zig");
    _ = @import("store/mock_store.zig");
    _ = @import("entry.zig");
    _ = @import("storage/default_storage.zig");
    _ = @import("object.zig");
    _ = @import("expiration.zig");
    _ = @import("cron.zig");
    _ = @import("connection.zig");
    _ = @import("config.zig");
    _ = @import("config_parser.zig");
    _ = @import("persistence/manifest.zig");
    _ = @import("persistence/aof.zig");
    _ = @import("change_tracker.zig");
    _ = @import("server.zig");
}
