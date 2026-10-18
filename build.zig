const std = @import("std");

// Learn more about this file here: https://ziglang.org/learn/build-system
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const execution_guard = executionGuard(b, target);
    const build_options = b.addOptions();

    build_options.addOption([]const u8, "version", @import("build.zig.zon").version);
    build_options.addOption(bool, "persistence_test_controls", false);

    const exe = b.addExecutable(.{
        .name = "kgcache",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .error_tracing = true,
            .link_libc = true,
        }),
    });
    exe.root_module.addOptions("build_options", build_options);

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
    run_step.dependOn(execution_guard orelse &run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .error_tracing = true,
            .link_libc = true,
        }),
    });
    unit_tests.root_module.addOptions("build_options", build_options);

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(execution_guard orelse &run_unit_tests.step);

    const integration_runner = b.addExecutable(.{
        .name = "kgcache-integration",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    integration_runner.root_module.addOptions("build_options", build_options);
    integration_runner.root_module.addImport("protocol_fixtures", b.createModule(.{
        .root_source_file = b.path("src/protocol/compatibility_fixtures.zig"),
    }));

    const control_protocol = b.createModule(.{
        .root_source_file = b.path("src/persistence/test_control_protocol.zig"),
    });
    const server_process = b.createModule(.{
        .root_source_file = b.path("tests/integration/harness/server_process.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    server_process.addImport("persistence_test_protocol", control_protocol);
    integration_runner.root_module.addImport("server_process", server_process);

    const control_options = b.addOptions();
    control_options.addOption([]const u8, "version", @import("build.zig.zon").version);
    control_options.addOption(bool, "persistence_test_controls", true);
    const controlled_server = b.addExecutable(.{
        .name = "kgcache-controlled-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .error_tracing = true,
            .link_libc = true,
        }),
    });
    controlled_server.root_module.addOptions("build_options", control_options);

    const fake_server = b.addExecutable(.{
        .name = "kgcache-fake-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/harness/fake_server.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const run_integration = b.addRunArtifact(integration_runner);
    run_integration.step.dependOn(&install_exe.step);
    run_integration.addArg(b.getInstallPath(.bin, exe.out_filename));
    run_integration.addArtifactArg(fake_server);
    run_integration.addArtifactArg(controlled_server);
    run_integration.has_side_effects = true;

    const integration_step = b.step("test-integration", "Run process integration tests");
    integration_step.dependOn(execution_guard orelse &run_integration.step);

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
        run_integration.addArgs(args);
    }
}

fn executionGuard(b: *std.Build, target: std.Build.ResolvedTarget) ?*std.Build.Step {
    const host = &b.graph.host.result;
    const candidate = &target.result;
    const executor = std.zig.system.getExternalExecutor(b.graph.io, host, candidate, .{
        .allow_darling = false,
        .allow_qemu = false,
        .allow_rosetta = false,
        .allow_wasmtime = false,
        .allow_wine = false,
        .link_libc = true,
    });
    const native = switch (executor) {
        .native => true,
        else => false,
    };
    if (native and host.cpu.features.isSuperSetOf(candidate.cpu.features)) return null;

    const message = b.fmt(
        "target {s} cannot run natively on build host {s}; use 'zig build' to compile it and run tests on the target platform",
        .{ candidate.zigTriple(b.allocator) catch @panic("out of memory"), host.zigTriple(b.allocator) catch @panic("out of memory") },
    );
    return &b.addFail(message).step;
}
