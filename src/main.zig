const std = @import("std");
const application = @import("application");
const logging = application.logging;

pub fn main(init: std.process.Init) u8 {
    // Server borrows this logger through the shared application lifecycle.
    var default_logger = logging.DefaultLogger.init(init.io);

    // The application reports source errors before returning.
    application.run(init, default_logger.logger(), .{}) catch return 1;
    return 0;
}
