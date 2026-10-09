const std = @import("std");
const ping_smoke = @import("suites/ping_smoke.zig");
const set_get = @import("suites/set_get.zig");
const command_errors = @import("suites/command_errors.zig");
const select_isolation = @import("suites/select_isolation.zig");
const invalid_config = @import("suites/invalid_config.zig");
const configuration = @import("suites/configuration.zig");
const idle_clients_shutdown = @import("suites/idle_clients_shutdown.zig");
const restart_same_port = @import("suites/restart_same_port.zig");
const two_servers = @import("suites/two_servers.zig");
const process_harness = @import("suites/process_harness.zig");
const aof_recovery = @import("suites/aof_recovery.zig");

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip();

    const executable_path = args.next() orelse return error.MissingExecutablePath;
    const fake_executable_path = args.next() orelse return error.MissingFakeExecutablePath;
    if (args.next() != null) return error.UnexpectedArgument;
    if (!std.fs.path.isAbsolute(executable_path)) return error.ExecutablePathNotAbsolute;

    const stat = try std.Io.Dir.cwd().statFile(init.io, executable_path, .{});
    if (stat.kind != .file) return error.ExecutablePathNotFile;
    const fake_stat = try std.Io.Dir.cwd().statFile(init.io, fake_executable_path, .{});
    if (fake_stat.kind != .file) return error.FakeExecutablePathNotFile;
    const fake_absolute_path = try std.Io.Dir.cwd().realPathFileAlloc(init.io, fake_executable_path, init.gpa);
    defer init.gpa.free(fake_absolute_path);

    const artifact_dir = std.process.Environ.getPosix(init.minimal.environ, "KGCACHE_TEST_ARTIFACT_DIR");
    try ping_smoke.run(init.io, init.gpa, executable_path, artifact_dir);
    try set_get.run(init.io, init.gpa, executable_path, artifact_dir);
    try command_errors.run(init.io, init.gpa, executable_path, artifact_dir);
    try select_isolation.run(init.io, init.gpa, executable_path, artifact_dir);
    try invalid_config.run(init.io, init.gpa, executable_path, artifact_dir);
    try configuration.run(init.io, init.gpa, executable_path, artifact_dir);
    try aof_recovery.run(init.io, init.gpa, executable_path, artifact_dir);
    try idle_clients_shutdown.run(init.io, init.gpa, executable_path, artifact_dir);
    try restart_same_port.run(init.io, init.gpa, executable_path, artifact_dir);
    try two_servers.run(init.io, init.gpa, executable_path, artifact_dir);
    try process_harness.run(init.io, init.gpa, executable_path, fake_absolute_path, artifact_dir);
}
