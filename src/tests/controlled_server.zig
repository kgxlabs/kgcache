const std = @import("std");
const application = @import("application");
const logging = application.logging;
const PersistenceController = @import("persistence_controller.zig");

pub fn main(init: std.process.Init) u8 {
    var default_logger = logging.DefaultLogger.init(init.io);
    var controller = PersistenceController.init(init.minimal.environ);
    defer controller.deinit();

    application.run(init, default_logger.logger(), controller.options()) catch return 1;
    return 0;
}
