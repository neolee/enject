const std = @import("std");
const cli = @import("enject").cli;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(allocator);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(init.io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    var runtime = try cli.defaultRuntimeAlloc(allocator, init);
    defer cli.deinitRuntime(allocator, &runtime);
    const program_name = cli.displayProgramName(args[0]);

    const command = cli.parseCommand(args) catch |err| {
        try stderr.print("error: {s}\n", .{describeError(err)});
        try cli.printUsage(stderr, program_name);
        try stderr.flush();
        std.process.exit(1);
    };

    const exit_code: u8 = blk: {
        switch (command) {
            .help => {
                try cli.printUsage(stdout, program_name);
                try stdout.flush();
                break :blk 0;
            },
            .trust => {
                const trusted_path = cli.trustNearestConfigAlloc(allocator, runtime) catch |err| {
                    try stderr.print("error: {s}\n", .{describeError(err)});
                    try stderr.flush();
                    std.process.exit(1);
                };
                defer allocator.free(trusted_path);

                try stdout.print("trusted {s}\n", .{trusted_path});
                try stdout.flush();
                break :blk 0;
            },
            .explain => |explain_cmd| {
                if (explain_cmd.check) {
                    var data = cli.doctorAlloc(allocator, runtime, explain_cmd.command_argv) catch |err| {
                        try stderr.print("error: {s}\n", .{describeError(err)});
                        try stderr.flush();
                        std.process.exit(1);
                    };
                    defer data.deinit(allocator);

                    try cli.renderDoctor(stdout, &data);
                    try stdout.flush();
                    break :blk 0;
                }

                var data = cli.explainAlloc(allocator, runtime, explain_cmd.command_argv) catch |err| {
                    try stderr.print("error: {s}\n", .{describeError(err)});
                    try stderr.flush();
                    std.process.exit(1);
                };
                defer data.deinit(allocator);

                try cli.renderExplain(stdout, &data);
                try stdout.flush();
                break :blk 0;
            },
            .secret => |secret_cmd| {
                switch (secret_cmd) {
                    .put => |put_cmd| {
                        const secret_value = if (put_cmd.value) |value|
                            value
                        else
                            cli.promptSecretValueAlloc(allocator, init.io, stderr, put_cmd.name) catch |err| {
                                try stderr.print("error: {s}\n", .{describeError(err)});
                                try stderr.flush();
                                std.process.exit(1);
                            };
                        defer if (put_cmd.value == null) allocator.free(secret_value);

                        const account = cli.putSecret(allocator, runtime, put_cmd.name, secret_value) catch |err| {
                            try stderr.print("error: {s}\n", .{describeError(err)});
                            try stderr.flush();
                            std.process.exit(1);
                        };
                        defer allocator.free(account);
                        try stdout.print("stored {s}\n", .{account});
                    },
                    .ls => {
                        const accounts = cli.listSecretsAlloc(allocator, runtime) catch |err| {
                            try stderr.print("error: {s}\n", .{describeError(err)});
                            try stderr.flush();
                            std.process.exit(1);
                        };
                        defer {
                            for (accounts) |account| allocator.free(account);
                            allocator.free(accounts);
                        }
                        for (accounts) |account| {
                            try stdout.print("{s}\n", .{account});
                        }
                    },
                    .rm => |name| {
                        const account = cli.removeSecret(allocator, runtime, name) catch |err| {
                            try stderr.print("error: {s}\n", .{describeError(err)});
                            try stderr.flush();
                            std.process.exit(1);
                        };
                        defer allocator.free(account);
                        try stdout.print("removed {s}\n", .{account});
                    },
                }
                try stdout.flush();
                break :blk 0;
            },
            .import_env => |import_cmd| {
                const imported = cli.importSecretsAlloc(allocator, runtime, import_cmd) catch |err| {
                    try stderr.print("error: {s}\n", .{describeError(err)});
                    try stderr.flush();
                    std.process.exit(1);
                };
                defer {
                    for (imported) |item| {
                        allocator.free(item.env_name);
                        allocator.free(item.account);
                    }
                    allocator.free(imported);
                }

                for (imported) |item| {
                    try stdout.print("imported {s} -> {s}\n", .{ item.env_name, item.account });
                }
                try stdout.print("total: {d}\n", .{imported.len});
                try stdout.flush();
                break :blk 0;
            },
            .run => |command_argv| {
                var run_result = cli.runCommand(allocator, runtime, command_argv, stderr) catch |err| {
                    try stderr.print("error: {s}\n", .{describeError(err)});
                    try stderr.flush();
                    std.process.exit(1);
                };
                defer run_result.deinit(allocator);

                break :blk switch (run_result.term) {
                    .exited => |code| code,
                    .signal => |sig| @truncate(128 + @intFromEnum(sig)),
                    .stopped, .unknown => 1,
                };
            },
        }
    };

    std.process.exit(exit_code);
}

fn describeError(err: anyerror) []const u8 {
    return switch (err) {
        error.MissingCommand => "missing command",
        error.MissingSubcommand => "missing subcommand",
        error.MissingValue => "missing value",
        error.UnexpectedArgument => "unexpected argument",
        error.UnknownSubcommand => "unknown subcommand",
        error.ProjectConfigNotFound => "no .enject file found from the current directory upward",
        error.BindingConflict => "conflicting bindings resolved for the same environment variable",
        error.NotFound => "secret not found",
        error.FileNotFound => "file not found",
        error.MissingProjectName => "project-scoped lookup requires [project].name",
        error.InvalidKeychainBackend => "invalid ENJECT_KEYCHAIN_BACKEND value (expected native or security_cli)",
        error.NotATerminal => "interactive secret input requires a terminal",
        else => @errorName(err),
    };
}
