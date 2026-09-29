const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip();

    const executable_path = args.next() orelse return error.MissingExecutablePath;
    if (args.next() != null) return error.UnexpectedArgument;
    if (!std.fs.path.isAbsolute(executable_path)) return error.ExecutablePathNotAbsolute;

    const stat = try std.Io.Dir.cwd().statFile(init.io, executable_path, .{});
    if (stat.kind != .file) return error.ExecutablePathNotFile;

    // Step 4 adds the first process test. This currently verifies only the
    // build input that every future process test will use.
}
