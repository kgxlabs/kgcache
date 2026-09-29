const std = @import("std");

// Learn more about this file here: https://ziglang.org/learn/build-system
pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const exe = b.addExecutable(.{
        .name = "kgcache",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .error_tracing = true,
            .link_libc = true,
        }),
    });

    // Share the install step with the integration runner so it receives the
    // absolute path of the executable that was just built.
    const install_exe = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install_exe.step);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .error_tracing = true,
            .link_libc = true,
        }),
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const integration_runner = b.addExecutable(.{
        .name = "kgcache-integration",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/main.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    const run_integration = b.addRunArtifact(integration_runner);
    run_integration.step.dependOn(&install_exe.step);
    run_integration.addArg(b.getInstallPath(.bin, exe.out_filename));
    run_integration.has_side_effects = true;

    const integration_step = b.step("test-integration", "Run process integration tests");
    integration_step.dependOn(&run_integration.step);

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
        run_integration.addArgs(args);
    }
}
