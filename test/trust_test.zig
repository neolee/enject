const std = @import("std");
const support = @import("support.zig");

test "trust store invalidates when trusted config changes" {
    const allocator = std.testing.allocator;
    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    const initial_config =
        \\version = 1
        \\
        \\[project]
        \\name = "acme"
        \\
    ;
    const updated_config =
        \\version = 1
        \\
        \\[project]
        \\name = "acme2"
        \\
    ;

    try temp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = ".enject",
        .data = initial_config,
    });

    const root_path = try support.tempRootPathAlloc(allocator, &temp_dir);
    defer allocator.free(root_path);
    const config_path = try std.fs.path.join(allocator, &.{ root_path, ".enject" });
    defer allocator.free(config_path);
    const trust_store_path = try std.fs.path.join(allocator, &.{ root_path, "trust.tsv" });
    defer allocator.free(trust_store_path);

    const trust_store = support.trust.Store.init(trust_store_path, std.testing.io);
    try trust_store.trustConfig(allocator, config_path);
    try std.testing.expect(try trust_store.isTrusted(allocator, config_path));

    try temp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = ".enject",
        .data = updated_config,
    });
    try std.testing.expect(!(try trust_store.isTrusted(allocator, config_path)));

    try trust_store.trustConfig(allocator, config_path);
    try std.testing.expect(try trust_store.isTrusted(allocator, config_path));
}

test "discoverProjectConfigAlloc prefers the nearest project root" {
    const allocator = std.testing.allocator;
    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    const outer_config =
        \\version = 1
        \\
        \\[project]
        \\name = "outer"
        \\
    ;
    const inner_config =
        \\version = 1
        \\
        \\[project]
        \\name = "inner"
        \\
    ;

    try temp_dir.dir.createDirPath(std.testing.io, "outer/inner/nested");
    try temp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "outer/.enject",
        .data = outer_config,
    });
    try temp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "outer/inner/.enject",
        .data = inner_config,
    });

    const root_path = try support.tempRootPathAlloc(allocator, &temp_dir);
    defer allocator.free(root_path);
    const outer_path = try std.fs.path.join(allocator, &.{ root_path, "outer", ".enject" });
    defer allocator.free(outer_path);
    const inner_path = try std.fs.path.join(allocator, &.{ root_path, "outer", "inner", ".enject" });
    defer allocator.free(inner_path);
    const trust_store_path = try std.fs.path.join(allocator, &.{ root_path, "trust.tsv" });
    defer allocator.free(trust_store_path);
    const cwd_path = try std.fs.path.join(allocator, &.{ root_path, "outer", "inner", "nested" });
    defer allocator.free(cwd_path);

    const trust_store = support.trust.Store.init(trust_store_path, std.testing.io);
    try trust_store.trustConfig(allocator, outer_path);
    try trust_store.trustConfig(allocator, inner_path);

    var discovery = try trust_store.discoverProjectConfigAlloc(allocator, cwd_path);
    defer discovery.deinit(allocator);

    try std.testing.expect(discovery.trusted != null);
    try std.testing.expect(discovery.untrusted == null);
    try std.testing.expectEqualStrings(inner_path, discovery.trusted.?.config_path);
}
