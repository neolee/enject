const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const codesign = resolveCodesignOptions(b, target);
    const enject_mod = addEnjectModule(b, target, optimize);
    const exe = addExecutableArtifact(b, target, optimize, enject_mod, "enject");
    b.getInstallStep().dependOn(installExecutableArtifact(b, exe, codesign));

    const run_step = b.step("run", "Run the enject CLI");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

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

    addReleaseStep(b, target, .ReleaseSafe, codesign, "release-safe", "Build and install a ReleaseSafe enject binary");
    addReleaseStep(b, target, .ReleaseFast, codesign, "release-fast", "Build and install a ReleaseFast enject binary");
}

const CodesignOptions = struct {
    enabled: bool,
    identity: ?[]const u8,
    identifier: []const u8,
};

fn resolveCodesignOptions(b: *std.Build, target: std.Build.ResolvedTarget) CodesignOptions {
    const enabled = b.option(bool, "codesign", "Sign the installed enject binary with macOS codesign") orelse false;
    const identity = b.option([]const u8, "codesign-identity", "macOS code signing identity") orelse
        getEnvVar(b, "ENJECT_CODESIGN_IDENTITY");
    const identifier = b.option([]const u8, "codesign-identifier", "macOS code signing identifier") orelse
        getEnvVar(b, "ENJECT_CODESIGN_IDENTIFIER") orelse
        "net.paradigmx.enject";

    if (enabled and identity == null) {
        @panic("codesign requested but no identity was provided; set ENJECT_CODESIGN_IDENTITY or pass -Dcodesign-identity");
    }
    if (enabled and target.result.os.tag != .macos) {
        @panic("codesign requested for a non-macOS target");
    }

    return .{
        .enabled = enabled,
        .identity = identity,
        .identifier = identifier,
    };
}

fn getEnvVar(b: *std.Build, name: []const u8) ?[]const u8 {
    return b.graph.environ_map.get(name);
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

fn createEnjectModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const toml_dep = b.dependency("toml", .{
        .target = target,
        .optimize = optimize,
    });

    const enject_mod = b.createModule(.{
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

fn installExecutableArtifact(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    codesign: CodesignOptions,
) *std.Build.Step {
    const install = b.addInstallArtifact(exe, .{});
    if (!codesign.enabled) return &install.step;

    const copied = b.addTempFiles().addCopyFile(exe.getEmittedBin(), exe.name);
    const sign = b.addSystemCommand(&.{
        "codesign",
        "--force",
        "--sign",
        codesign.identity.?,
        "--timestamp=none",
        "--identifier",
        codesign.identifier,
    });
    sign.addFileArg(copied);

    const signed_install = b.addInstallBinFile(copied, exe.name);
    signed_install.step.dependOn(&sign.step);
    return &signed_install.step;
}

fn addReleaseStep(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    codesign: CodesignOptions,
    step_name: []const u8,
    step_description: []const u8,
) void {
    const enject_mod = createEnjectModule(b, target, optimize);
    const exe = addExecutableArtifact(b, target, optimize, enject_mod, "enject");
    const step = b.step(step_name, step_description);
    step.dependOn(installExecutableArtifact(b, exe, codesign));
}
