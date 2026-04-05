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
        try stderr.print("error: {t}\n", .{err});
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
                    try stderr.print("error: {t}\n", .{err});
                    try stderr.flush();
                    std.process.exit(1);
                };
                defer allocator.free(trusted_path);

                try stdout.print("trusted {s}\n", .{trusted_path});
                try stdout.flush();
                break :blk 0;
            },
            .explain => |command_argv| {
                var data = cli.explainAlloc(allocator, runtime, command_argv) catch |err| {
                    try stderr.print("error: {t}\n", .{err});
                    try stderr.flush();
                    std.process.exit(1);
                };
                defer data.deinit(allocator);

                try cli.renderExplain(stdout, &data);
                try stdout.flush();
                break :blk 0;
            },
            .run => |command_argv| {
                const term = cli.runCommand(allocator, runtime, command_argv) catch |err| {
                    try stderr.print("error: {t}\n", .{err});
                    try stderr.flush();
                    std.process.exit(1);
                };
                break :blk switch (term) {
                    .exited => |code| code,
                    .signal => |sig| @truncate(128 + @intFromEnum(sig)),
                    .stopped, .unknown => 1,
                };
            },
        }
    };

    std.process.exit(exit_code);
}
