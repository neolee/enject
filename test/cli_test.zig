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

    const secret_put = try cli.parseCommand(&.{ "enject", "secret", "put", "OPENAI_API_KEY", "--value", "abc" });
    try std.testing.expectEqualStrings("OPENAI_API_KEY", secret_put.secret.put.name);
    try std.testing.expectEqualStrings("abc", secret_put.secret.put.value.?);

    const secret_put_interactive = try cli.parseCommand(&.{ "enject", "secret", "put", "OPENAI_API_KEY" });
    try std.testing.expectEqualStrings("OPENAI_API_KEY", secret_put_interactive.secret.put.name);
    try std.testing.expect(secret_put_interactive.secret.put.value == null);

    const secret_ls = try cli.parseCommand(&.{ "enject", "secret", "ls" });
    try std.testing.expectEqualDeep(cli.SecretCommand.ls, secret_ls.secret);

    const import_cmd = try cli.parseCommand(&.{ "enject", "import", "keys.env", "--project", "acme", "--key", "DATABASE_URL" });
    try std.testing.expectEqualStrings("keys.env", import_cmd.import_env.file_path);
    try std.testing.expectEqualStrings("acme", import_cmd.import_env.project_name.?);
    try std.testing.expectEqualStrings("DATABASE_URL", import_cmd.import_env.env_key.?);
}

test "cli resolveKeychainBackend honors ENJECT_KEYCHAIN_BACKEND override" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("ENJECT_KEYCHAIN_BACKEND", "native");
    try std.testing.expectEqual(enject.providers.keychain.Backend.native, try cli.resolveKeychainBackend(&env_map));

    var env_map_cli = std.process.Environ.Map.init(allocator);
    defer env_map_cli.deinit();
    try env_map_cli.put("ENJECT_KEYCHAIN_BACKEND", "security_cli");
    try std.testing.expectEqual(enject.providers.keychain.Backend.security_cli, try cli.resolveKeychainBackend(&env_map_cli));
}

test "cli resolveKeychainBackend rejects invalid override" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("ENJECT_KEYCHAIN_BACKEND", "bogus");

    try std.testing.expectError(error.InvalidKeychainBackend, cli.resolveKeychainBackend(&env_map));
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
    try std.testing.expect(std.mem.indexOf(u8, output, "Explain") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Resolution mode: config and rule resolution only (no secrets read)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Command: codex") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Context") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Bindings") != null);
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

    var warning_writer: std.Io.Writer.Allocating = .init(allocator);
    defer warning_writer.deinit();

    var run_result = try cli.runCommand(allocator, runtime, &.{ "/bin/sh", "-c", "test \"$OPENAI_API_KEY\" = \"cli-injected-secret\"" }, &warning_writer.writer);
    defer run_result.deinit(allocator);

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, run_result.term);
    try std.testing.expectEqual(@as(usize, 0), run_result.missing_secrets.len);
    try std.testing.expectEqualStrings("", warning_writer.written());
}

test "cli runCommand skips missing secrets and still runs child process" {
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

    const runtime = cli.Runtime{
        .io = std.testing.io,
        .environ_map = &env_map,
        .cwd_path = cwd_path,
        .global_config_path = global_config_path,
        .trust_store_path = trust_store_path,
        .service = support.test_service,
        .keychain_backend = .native,
    };

    var warning_writer: std.Io.Writer.Allocating = .init(allocator);
    defer warning_writer.deinit();

    var run_result = try cli.runCommand(allocator, runtime, &.{ "/bin/sh", "-c", "test -z \"$OPENAI_API_KEY\"" }, &warning_writer.writer);
    defer run_result.deinit(allocator);

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, run_result.term);
    try std.testing.expectEqual(@as(usize, 1), run_result.missing_secrets.len);
    try std.testing.expectEqualStrings("OPENAI_API_KEY", run_result.missing_secrets[0].env_name);
    try std.testing.expectEqualStrings(support.test_service, run_result.missing_secrets[0].service);
    try std.testing.expectEqualStrings("openai_api_key", run_result.missing_secrets[0].account);
    try std.testing.expect(std.mem.indexOf(u8, warning_writer.written(), "warning: secret not found for OPENAI_API_KEY") != null);
}

test "cli secret put ls and rm manage keychain entries" {
    const allocator = std.testing.allocator;
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    const root_path = try support.tempRootPathAlloc(allocator, &temp_dir);
    defer allocator.free(root_path);
    const trust_store_path = try std.fs.path.join(allocator, &.{ root_path, "trust.tsv" });
    defer allocator.free(trust_store_path);

    const runtime = cli.Runtime{
        .io = std.testing.io,
        .environ_map = &env_map,
        .cwd_path = root_path,
        .global_config_path = null,
        .trust_store_path = trust_store_path,
        .service = "com.github.neolee.enject.tests.cli",
    };

    const account = try cli.putSecret(allocator, runtime, "OPENAI_API_KEY", "secret-one");
    defer allocator.free(account);
    try std.testing.expectEqualStrings("openai_api_key", account);

    const accounts_after_put = try cli.listSecretsAlloc(allocator, runtime);
    defer {
        for (accounts_after_put) |item| allocator.free(item);
        allocator.free(accounts_after_put);
    }

    var found = false;
    for (accounts_after_put) |item| {
        if (std.mem.eql(u8, item, "openai_api_key")) found = true;
    }
    try std.testing.expect(found);

    const removed = try cli.removeSecret(allocator, runtime, "OPENAI_API_KEY");
    defer allocator.free(removed);
    try std.testing.expectEqualStrings("openai_api_key", removed);

    const accounts_after_rm = try cli.listSecretsAlloc(allocator, runtime);
    defer {
        for (accounts_after_rm) |item| allocator.free(item);
        allocator.free(accounts_after_rm);
    }
    for (accounts_after_rm) |item| {
        try std.testing.expect(!std.mem.eql(u8, item, "openai_api_key"));
    }
}

test "cli importSecretsAlloc imports global and project scoped secrets" {
    const allocator = std.testing.allocator;
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    try temp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "keys.env",
        .data = @embedFile("fixtures/keys.env"),
    });

    const root_path = try support.tempRootPathAlloc(allocator, &temp_dir);
    defer allocator.free(root_path);
    const trust_store_path = try std.fs.path.join(allocator, &.{ root_path, "trust.tsv" });
    defer allocator.free(trust_store_path);
    const file_path = try std.fs.path.join(allocator, &.{ root_path, "keys.env" });
    defer allocator.free(file_path);

    const runtime = cli.Runtime{
        .io = std.testing.io,
        .environ_map = &env_map,
        .cwd_path = root_path,
        .global_config_path = null,
        .trust_store_path = trust_store_path,
        .service = "com.github.neolee.enject.tests.import",
    };

    const imported = try cli.importSecretsAlloc(allocator, runtime, .{
        .file_path = file_path,
        .project_name = "acme",
        .env_key = "DATABASE_URL",
    });
    defer {
        for (imported) |item| {
            allocator.free(item.env_name);
            allocator.free(item.account);
        }
        allocator.free(imported);
    }

    try std.testing.expectEqual(@as(usize, 1), imported.len);
    try std.testing.expectEqualStrings("DATABASE_URL", imported[0].env_name);
    try std.testing.expectEqualStrings("acme/database_url", imported[0].account);

    const store = support.keychain.Store.init(.native, std.testing.io);
    defer store.deleteGenericPassword(allocator, .{
        .service = runtime.service,
        .account = "acme/database_url",
    }) catch {};

    const loaded = try store.readGenericPasswordAlloc(allocator, .{
        .service = runtime.service,
        .account = "acme/database_url",
    });
    defer allocator.free(loaded);
    try std.testing.expectEqualStrings("postgres://acme:password@localhost/acme", loaded);
}
