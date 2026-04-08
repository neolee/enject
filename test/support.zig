const std = @import("std");
const enject = @import("enject");

pub const test_service = "com.github.neolee.enject.tests";
pub const store = enject.providers.store;
pub const resolver = enject.core.resolver;
pub const trust = enject.trust.store;

pub fn expectRoundTrip(
    secret_store: store.Store,
    allocator: std.mem.Allocator,
    target: store.Target,
    expected_value: []const u8,
) !void {
    secret_store.delete(allocator, target) catch |err| switch (err) {
        error.NotFound => {},
        else => return err,
    };

    try secret_store.set(allocator, target, expected_value);

    const loaded = try secret_store.getAlloc(allocator, target);
    defer allocator.free(loaded);

    try std.testing.expectEqualStrings(expected_value, loaded);

    try secret_store.delete(allocator, target);
    _ = secret_store.getAlloc(allocator, target) catch |err| switch (err) {
        error.NotFound => return,
        else => return err,
    };

    return error.ExpectedMissingPassword;
}

pub fn tempRootPathAlloc(allocator: std.mem.Allocator, temp_dir: *std.testing.TmpDir) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.resolve(allocator, &.{ cwd, ".zig-cache", "tmp", temp_dir.sub_path[0..] });
}

pub fn expectAccount(
    bindings: []const resolver.ResolvedBinding,
    env_name: []const u8,
    account: []const u8,
) !void {
    for (bindings) |binding| {
        if (std.mem.eql(u8, binding.env_name, env_name)) {
            switch (binding.value_source) {
                .secret => |secret| try std.testing.expectEqualStrings(account, secret.account),
                .env => return error.ExpectedSecretBinding,
            }
            return;
        }
    }
    return error.MissingExpectedBinding;
}

pub fn expectEnvAlias(
    bindings: []const resolver.ResolvedBinding,
    env_name: []const u8,
    target_env_name: []const u8,
) !void {
    for (bindings) |binding| {
        if (std.mem.eql(u8, binding.env_name, env_name)) {
            switch (binding.value_source) {
                .secret => return error.ExpectedEnvAliasBinding,
                .env => |target| try std.testing.expectEqualStrings(target_env_name, target),
            }
            return;
        }
    }
    return error.MissingExpectedBinding;
}
