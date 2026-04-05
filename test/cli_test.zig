const std = @import("std");
const enject = @import("enject");
const support = @import("support.zig");

const cli = enject.cli;

test "cli parseCommand handles help run explain trust and shorthand" {
    try std.testing.expectEqualDeep(cli.ParsedCommand.help, try cli.parseCommand(&.{"enject"}));
    try std.testing.expectEqualDeep(cli.ParsedCommand.help, try cli.parseCommand(&.{ "enject", "--help" }));
    try std.testing.expectEqualDeep(cli.ParsedCommand.trust, try cli.parseCommand(&.{ "enject", "trust" }));

    const explain = try cli.parseCommand(&.{ "enject", "explain", "--", "codex" });
    try std.testing.expectEqualStrings("codex", explain.explain[0]);

    const run_cmd = try cli.parseCommand(&.{ "enject", "run", "--", "uv", "run" });
    try std.testing.expectEqualStrings("uv", run_cmd.run[0]);
    try std.testing.expectEqualStrings("run", run_cmd.run[1]);

    const shorthand = try cli.parseCommand(&.{ "enject", "codex" });
    try std.testing.expectEqualStrings("codex", shorthand.run[0]);
}

test "cli trustNearestConfigAlloc trusts nearest project config" {
    const allocator = std.testing.allocator;
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    const project_config =
        \\version = 1
        \\
        \\[project]
        \\name = "acme"
        \\
    ;

    try temp_dir.dir.createDirPath(std.testing.io, "project/nested");
    try temp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "project/.enject",
        .data = project_config,
    });

    const root_path = try support.tempRootPathAlloc(allocator, &temp_dir);
    defer allocator.free(root_path);
    const project_root = try std.fs.path.join(allocator, &.{ root_path, "project" });
    defer allocator.free(project_root);
    const cwd_path = try std.fs.path.join(allocator, &.{ root_path, "project", "nested" });
    defer allocator.free(cwd_path);
    const trust_store_path = try std.fs.path.join(allocator, &.{ root_path, ".config", "enject", "trust.tsv" });
    defer allocator.free(trust_store_path);
    const config_path = try std.fs.path.join(allocator, &.{ project_root, ".enject" });
    defer allocator.free(config_path);

    const runtime = cli.Runtime{
        .io = std.testing.io,
        .environ_map = &env_map,
        .cwd_path = cwd_path,
        .global_config_path = null,
        .trust_store_path = trust_store_path,
    };

    const trusted_path = try cli.trustNearestConfigAlloc(allocator, runtime);
    defer allocator.free(trusted_path);

    try std.testing.expectEqualStrings(config_path, trusted_path);

    const trust_store = support.trust.Store.init(trust_store_path, std.testing.io);
    try std.testing.expect(try trust_store.isTrusted(allocator, config_path));
}

test "cli explain renders trusted project resolution" {
    const allocator = std.testing.allocator;
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

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
        \\project = ["DATABASE_URL"]
        \\
        \\[bindings]
        \\DATABASE_URL = { account = "staging/database_url" }
        \\
    ;

    try temp_dir.dir.createDirPath(std.testing.io, "project/nested");
    try temp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "project/.enject",
        .data = project_config_text,
    });
    try temp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "config.toml",
        .data = global_config_text,
    });

    const root_path = try support.tempRootPathAlloc(allocator, &temp_dir);
    defer allocator.free(root_path);
    const cwd_path = try std.fs.path.join(allocator, &.{ root_path, "project", "nested" });
    defer allocator.free(cwd_path);
    const global_config_path = try std.fs.path.join(allocator, &.{ root_path, "config.toml" });
    defer allocator.free(global_config_path);
    const trust_store_path = try std.fs.path.join(allocator, &.{ root_path, "trust.tsv" });
    defer allocator.free(trust_store_path);
    const project_config_path = try std.fs.path.join(allocator, &.{ root_path, "project", ".enject" });
    defer allocator.free(project_config_path);

    const trust_store = support.trust.Store.init(trust_store_path, std.testing.io);
    try trust_store.trustConfig(allocator, project_config_path);

    const runtime = cli.Runtime{
        .io = std.testing.io,
        .environ_map = &env_map,
        .cwd_path = cwd_path,
        .global_config_path = global_config_path,
        .trust_store_path = trust_store_path,
        .service = support.test_service,
    };

    var explain_data = try cli.explainAlloc(allocator, runtime, &.{"codex"});
    defer explain_data.deinit(allocator);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try cli.renderExplain(&aw.writer, &explain_data);

    const output = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, output, "command: codex") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "project config:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "OPENAI_API_KEY") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "DATABASE_URL") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "staging/database_url") != null);
}

test "cli runCommand injects resolved environment into child process" {
    const allocator = std.testing.allocator;
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    const global_config_text =
        \\version = 1
        \\
        \\[[rules.command]]
        \\match.argv_prefix = ["/bin/sh", "-c"]
        \\inject.global = ["OPENAI_API_KEY"]
        \\
    ;

    try temp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "config.toml",
        .data = global_config_text,
    });

    const root_path = try support.tempRootPathAlloc(allocator, &temp_dir);
    defer allocator.free(root_path);
    const cwd_path = try allocator.dupe(u8, root_path);
    defer allocator.free(cwd_path);
    const global_config_path = try std.fs.path.join(allocator, &.{ root_path, "config.toml" });
    defer allocator.free(global_config_path);
    const trust_store_path = try std.fs.path.join(allocator, &.{ root_path, "trust.tsv" });
    defer allocator.free(trust_store_path);

    const store = support.keychain.Store.init(.native, std.testing.io);
    const target = support.keychain.GenericPasswordTarget{
        .service = support.test_service,
        .account = "openai_api_key",
    };
    store.deleteGenericPassword(allocator, target) catch |err| switch (err) {
        error.NotFound => {},
        else => return err,
    };
    defer store.deleteGenericPassword(allocator, target) catch {};
    try store.writeGenericPassword(allocator, target, "cli-injected-secret");

    const runtime = cli.Runtime{
        .io = std.testing.io,
        .environ_map = &env_map,
        .cwd_path = cwd_path,
        .global_config_path = global_config_path,
        .trust_store_path = trust_store_path,
        .service = support.test_service,
        .keychain_backend = .native,
    };

    const term = try cli.runCommand(allocator, runtime, &.{ "/bin/sh", "-c", "test \"$OPENAI_API_KEY\" = \"cli-injected-secret\"" });
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, term);
}
