const std = @import("std");
const enject = @import("enject");
const support = @import("support.zig");

const parser = enject.config.parser;
const fixture_global_config = @embedFile("fixtures/global-config.toml");
const fixture_project_config = @embedFile("fixtures/project.enject");

test "resolver loads trusted project config and resolves merged bindings" {
    const allocator = std.testing.allocator;
    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    try temp_dir.dir.createDirPath(std.testing.io, "project/nested");
    try temp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "project/.enject",
        .data = fixture_project_config,
    });
    try temp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "global-config.toml",
        .data = fixture_global_config,
    });

    const root_path = try support.tempRootPathAlloc(allocator, &temp_dir);
    defer allocator.free(root_path);

    const project_config_path = try std.fs.path.join(allocator, &.{ root_path, "project", ".enject" });
    defer allocator.free(project_config_path);
    const global_config_path = try std.fs.path.join(allocator, &.{ root_path, "global-config.toml" });
    defer allocator.free(global_config_path);
    const trust_store_path = try std.fs.path.join(allocator, &.{ root_path, "trust.tsv" });
    defer allocator.free(trust_store_path);
    const cwd_path = try std.fs.path.join(allocator, &.{ root_path, "project", "nested" });
    defer allocator.free(cwd_path);

    const trust_store = support.trust.Store.init(trust_store_path, std.testing.io);
    try trust_store.trustConfig(allocator, project_config_path);

    var context = try support.resolver.loadContextAlloc(allocator, std.testing.io, .{
        .global_config_path = global_config_path,
        .cwd_path = cwd_path,
        .trust_store_path = trust_store_path,
    });
    defer context.deinit(allocator);

    try std.testing.expect(context.project_config != null);
    try std.testing.expect(context.ignored_untrusted_project_config_path == null);

    var resolution = try support.resolver.resolveAlloc(allocator, &context, &.{ "uv", "run", "rag.py" }, support.resolver.default_service);
    defer resolution.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), resolution.bindings.len);
    try support.expectAccount(resolution.bindings, "OPENAI_API_KEY", "openai_api_key");
    try support.expectAccount(resolution.bindings, "DEEPSEEK_API_KEY", "deepseek_api_key");
    try support.expectAccount(resolution.bindings, "DATABASE_URL", "staging/database_url");
}

test "resolver ignores untrusted project config" {
    const allocator = std.testing.allocator;
    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    try temp_dir.dir.createDirPath(std.testing.io, "project/nested");
    try temp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "project/.enject",
        .data = fixture_project_config,
    });
    try temp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "global-config.toml",
        .data = fixture_global_config,
    });

    const root_path = try support.tempRootPathAlloc(allocator, &temp_dir);
    defer allocator.free(root_path);

    const global_config_path = try std.fs.path.join(allocator, &.{ root_path, "global-config.toml" });
    defer allocator.free(global_config_path);
    const trust_store_path = try std.fs.path.join(allocator, &.{ root_path, "trust.tsv" });
    defer allocator.free(trust_store_path);
    const cwd_path = try std.fs.path.join(allocator, &.{ root_path, "project", "nested" });
    defer allocator.free(cwd_path);

    var context = try support.resolver.loadContextAlloc(allocator, std.testing.io, .{
        .global_config_path = global_config_path,
        .cwd_path = cwd_path,
        .trust_store_path = trust_store_path,
    });
    defer context.deinit(allocator);

    try std.testing.expect(context.project_config == null);
    try std.testing.expect(context.ignored_untrusted_project_config_path != null);

    var resolution = try support.resolver.resolveAlloc(allocator, &context, &.{ "uv", "run", "rag.py" }, support.resolver.default_service);
    defer resolution.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), resolution.bindings.len);
    try support.expectAccount(resolution.bindings, "DEEPSEEK_API_KEY", "deepseek_api_key");
}

test "resolver deduplicates identical bindings from multiple matched sources" {
    const allocator = std.testing.allocator;
    const global_config_text =
        \\version = 1
        \\
        \\[[rules.command]]
        \\match.argv = ["codex"]
        \\inject.global = ["OPENAI_API_KEY"]
        \\
    ;
    const project_config_text =
        \\version = 1
        \\
        \\[project]
        \\name = "acme"
        \\
        \\[rules.directory]
        \\global = ["OPENAI_API_KEY"]
        \\
    ;

    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    try temp_dir.dir.createDirPath(std.testing.io, "project");
    try temp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "project/.enject",
        .data = project_config_text,
    });
    try temp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "global-config.toml",
        .data = global_config_text,
    });

    const root_path = try support.tempRootPathAlloc(allocator, &temp_dir);
    defer allocator.free(root_path);
    const project_config_path = try std.fs.path.join(allocator, &.{ root_path, "project", ".enject" });
    defer allocator.free(project_config_path);
    const global_config_path = try std.fs.path.join(allocator, &.{ root_path, "global-config.toml" });
    defer allocator.free(global_config_path);
    const trust_store_path = try std.fs.path.join(allocator, &.{ root_path, "trust.tsv" });
    defer allocator.free(trust_store_path);
    const cwd_path = try std.fs.path.join(allocator, &.{ root_path, "project" });
    defer allocator.free(cwd_path);

    const trust_store = support.trust.Store.init(trust_store_path, std.testing.io);
    try trust_store.trustConfig(allocator, project_config_path);

    var context = try support.resolver.loadContextAlloc(allocator, std.testing.io, .{
        .global_config_path = global_config_path,
        .cwd_path = cwd_path,
        .trust_store_path = trust_store_path,
    });
    defer context.deinit(allocator);

    var resolution = try support.resolver.resolveAlloc(allocator, &context, &.{ "codex" }, support.resolver.default_service);
    defer resolution.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), resolution.bindings.len);
    try support.expectAccount(resolution.bindings, "OPENAI_API_KEY", "openai_api_key");
}

test "resolver reports conflicting bindings for the same env" {
    const allocator = std.testing.allocator;
    const global_config_text =
        \\version = 1
        \\
        \\[[rules.command]]
        \\match.argv = ["codex"]
        \\inject.global = ["OPENAI_API_KEY"]
        \\
        \\[bindings]
        \\OPENAI_API_KEY = { account = "global/openai_api_key" }
        \\
    ;
    const project_config_text =
        \\version = 1
        \\
        \\[project]
        \\name = "acme"
        \\
        \\[rules.directory]
        \\global = ["OPENAI_API_KEY"]
        \\
        \\[bindings]
        \\OPENAI_API_KEY = { account = "project/openai_api_key" }
        \\
    ;

    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    try temp_dir.dir.createDirPath(std.testing.io, "project");
    try temp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "project/.enject",
        .data = project_config_text,
    });
    try temp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "global-config.toml",
        .data = global_config_text,
    });

    const root_path = try support.tempRootPathAlloc(allocator, &temp_dir);
    defer allocator.free(root_path);
    const project_config_path = try std.fs.path.join(allocator, &.{ root_path, "project", ".enject" });
    defer allocator.free(project_config_path);
    const global_config_path = try std.fs.path.join(allocator, &.{ root_path, "global-config.toml" });
    defer allocator.free(global_config_path);
    const trust_store_path = try std.fs.path.join(allocator, &.{ root_path, "trust.tsv" });
    defer allocator.free(trust_store_path);
    const cwd_path = try std.fs.path.join(allocator, &.{ root_path, "project" });
    defer allocator.free(cwd_path);

    const trust_store = support.trust.Store.init(trust_store_path, std.testing.io);
    try trust_store.trustConfig(allocator, project_config_path);

    var context = try support.resolver.loadContextAlloc(allocator, std.testing.io, .{
        .global_config_path = global_config_path,
        .cwd_path = cwd_path,
        .trust_store_path = trust_store_path,
    });
    defer context.deinit(allocator);

    try std.testing.expectError(
        error.BindingConflict,
        support.resolver.resolveAlloc(allocator, &context, &.{ "codex" }, support.resolver.default_service),
    );
}

test "resolver requires exact argv match when using match.argv" {
    const allocator = std.testing.allocator;
    const global_config = try parser.parseSliceAlloc(allocator,
        \\version = 1
        \\
        \\[[rules.command]]
        \\match.argv = ["uv", "run"]
        \\inject.global = ["OPENAI_API_KEY"]
        \\
    );

    var context = support.resolver.LoadedContext{
        .global_config = global_config,
    };
    defer context.deinit(allocator);

    var resolution = try support.resolver.resolveAlloc(allocator, &context, &.{ "uv", "run", "rag.py" }, support.resolver.default_service);
    defer resolution.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), resolution.bindings.len);
}

test "resolver matches argv_prefix against longer commands" {
    const allocator = std.testing.allocator;
    const global_config = try parser.parseSliceAlloc(allocator,
        \\version = 1
        \\
        \\[[rules.command]]
        \\match.argv_prefix = ["uv", "run"]
        \\inject.global = ["OPENAI_API_KEY"]
        \\
    );

    var context = support.resolver.LoadedContext{
        .global_config = global_config,
    };
    defer context.deinit(allocator);

    var resolution = try support.resolver.resolveAlloc(allocator, &context, &.{ "uv", "run", "rag.py" }, support.resolver.default_service);
    defer resolution.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), resolution.bindings.len);
    try support.expectAccount(resolution.bindings, "OPENAI_API_KEY", "openai_api_key");
}
