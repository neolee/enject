const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const enject_mod = addEnjectModule(b, target, optimize);
    const exe = addExecutableArtifact(b, target, optimize, enject_mod, "enject");
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the enject CLI");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const all_tests = b.addTest(.{
        .name = "all-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "enject", .module = enject_mod },
            },
        }),
    });
    linkPlatformLibs(all_tests.root_module, target);

    const run_all_tests = b.addRunArtifact(all_tests);
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_all_tests.step);

    addNamedTestStep(b, target, optimize, enject_mod, "test-providers", "Run provider tests", "all-tests-providers", "test/providers_test.zig");
    addNamedTestStep(b, target, optimize, enject_mod, "test-trust", "Run trust tests", "all-tests-trust", "test/trust_test.zig");
    addNamedTestStep(b, target, optimize, enject_mod, "test-config", "Run config tests", "all-tests-config", "test/config_test.zig");
    addNamedTestStep(b, target, optimize, enject_mod, "test-resolver", "Run resolver tests", "all-tests-resolver", "test/resolver_test.zig");
    addNamedTestStep(b, target, optimize, enject_mod, "test-cli", "Run CLI tests", "all-tests-cli", "test/cli_test.zig");

    addReleaseStep(b, target, .ReleaseSafe, "release-safe", "Build and install a ReleaseSafe enject binary");
    addReleaseStep(b, target, .ReleaseFast, "release-fast", "Build and install a ReleaseFast enject binary");
}

fn linkPlatformLibs(module: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    switch (target.result.os.tag) {
        .macos => {
            module.linkFramework("Security", .{});
            module.linkFramework("CoreFoundation", .{});
        },
        .linux => {
            // TODO(platform/linux): link libsecret-1 once the secret_service provider is implemented
        },
        .windows => {
            // TODO(platform/windows): link advapi32 once the wincred provider is implemented
        },
        else => {},
    }
}

fn addNamedTestStep(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    enject_mod: *std.Build.Module,
    step_name: []const u8,
    step_description: []const u8,
    artifact_name: []const u8,
    root_source_path: []const u8,
) void {
    const test_artifact = b.addTest(.{
        .name = artifact_name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(root_source_path),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "enject", .module = enject_mod },
            },
        }),
    });
    linkPlatformLibs(test_artifact.root_module, target);

    const run_artifact = b.addRunArtifact(test_artifact);
    const step = b.step(step_name, step_description);
    step.dependOn(&run_artifact.step);
}

fn addEnjectModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const toml_dep = b.dependency("toml", .{
        .target = target,
        .optimize = optimize,
    });

    const enject_mod = b.addModule("enject", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    enject_mod.addImport("toml", toml_dep.module("toml"));
    linkPlatformLibs(enject_mod, target);
    return enject_mod;
}

fn addExecutableArtifact(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    enject_mod: *std.Build.Module,
    name: []const u8,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "enject", .module = enject_mod },
            },
        }),
    });
    linkPlatformLibs(exe.root_module, target);
    return exe;
}

fn addReleaseStep(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    step_name: []const u8,
    step_description: []const u8,
) void {
    const enject_mod = addEnjectModule(b, target, optimize);
    const exe = addExecutableArtifact(b, target, optimize, enject_mod, "enject");
    const install = b.addInstallArtifact(exe, .{});
    const step = b.step(step_name, step_description);
    step.dependOn(&install.step);
}
