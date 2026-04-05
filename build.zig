const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const enject_mod = b.addModule("enject", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkAppleFrameworks(enject_mod);

    const exe = b.addExecutable(.{
        .name = "enject",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "enject", .module = enject_mod },
            },
        }),
    });
    linkAppleFrameworks(exe.root_module);
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the enject CLI");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const integration_tests = b.addTest(.{
        .name = "integration-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/integration.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "enject", .module = enject_mod },
            },
        }),
    });
    linkAppleFrameworks(integration_tests.root_module);

    const run_integration_tests = b.addRunArtifact(integration_tests);
    const test_step = b.step("test", "Run integration tests");
    test_step.dependOn(&run_integration_tests.step);
}

fn linkAppleFrameworks(module: *std.Build.Module) void {
    module.linkFramework("Security", .{});
    module.linkFramework("CoreFoundation", .{});
}
