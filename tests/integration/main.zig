const std = @import("std");
const ping_smoke = @import("suites/ping_smoke.zig");

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip();

    const executable_path = args.next() orelse return error.MissingExecutablePath;
    if (args.next() != null) return error.UnexpectedArgument;
    if (!std.fs.path.isAbsolute(executable_path)) return error.ExecutablePathNotAbsolute;

    const stat = try std.Io.Dir.cwd().statFile(init.io, executable_path, .{});
    if (stat.kind != .file) return error.ExecutablePathNotFile;

    try ping_smoke.run(init.io, init.gpa, executable_path);
}
