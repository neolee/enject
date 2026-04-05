const builtin = @import("builtin");
const std = @import("std");
const resolver = @import("../core/resolver.zig");
const keychain = @import("../providers/keychain.zig");
const trust = @import("../trust/store.zig");

pub const Runtime = struct {
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    cwd_path: []const u8,
    global_config_path: ?[]const u8,
    trust_store_path: []const u8,
    service: []const u8 = resolver.default_service,
    keychain_backend: keychain.Backend = defaultKeychainBackend(),
};

pub const ParsedCommand = union(enum) {
    help,
    trust,
    explain: []const []const u8,
    run: []const []const u8,
};

pub const ExplainData = struct {
    command_argv: []const []const u8,
    cwd_path: []const u8,
    global_config_path: ?[]const u8,
    context: resolver.LoadedContext,
    resolution: resolver.Resolution,

    pub fn deinit(self: *ExplainData, allocator: std.mem.Allocator) void {
        self.context.deinit(allocator);
        self.resolution.deinit(allocator);
        self.* = undefined;
    }
};

pub fn defaultRuntimeAlloc(allocator: std.mem.Allocator, init: std.process.Init) !Runtime {
    const cwd_path = try std.process.currentPathAlloc(init.io, allocator);
    errdefer allocator.free(cwd_path);

    const config_dir = try defaultConfigDirAlloc(allocator, init.environ_map);
    defer allocator.free(config_dir);

    const global_config_path = try std.fs.path.join(allocator, &.{ config_dir, "config.toml" });
    errdefer allocator.free(global_config_path);

    const trust_store_path = try std.fs.path.join(allocator, &.{ config_dir, "trust.tsv" });
    errdefer allocator.free(trust_store_path);

    return .{
        .io = init.io,
        .environ_map = init.environ_map,
        .cwd_path = cwd_path,
        .global_config_path = global_config_path,
        .trust_store_path = trust_store_path,
    };
}

pub fn deinitRuntime(allocator: std.mem.Allocator, runtime: *Runtime) void {
    allocator.free(runtime.cwd_path);
    if (runtime.global_config_path) |path| allocator.free(path);
    allocator.free(runtime.trust_store_path);
    runtime.* = undefined;
}

pub fn parseCommand(args: []const []const u8) !ParsedCommand {
    if (args.len <= 1) return .help;

    const verb = args[1];
    if (std.mem.eql(u8, verb, "-h") or std.mem.eql(u8, verb, "--help") or std.mem.eql(u8, verb, "help")) {
        return .help;
    }
    if (std.mem.eql(u8, verb, "trust")) {
        if (args.len != 2) return error.UnexpectedArgument;
        return .trust;
    }
    if (std.mem.eql(u8, verb, "explain")) {
        return .{ .explain = trimCommandSeparator(args[2..]) };
    }
    if (std.mem.eql(u8, verb, "run")) {
        return .{ .run = trimCommandSeparator(args[2..]) };
    }
    if (std.mem.eql(u8, verb, "--")) {
        return .{ .run = args[2..] };
    }
    return .{ .run = args[1..] };
}

pub fn trustNearestConfigAlloc(
    allocator: std.mem.Allocator,
    runtime: Runtime,
) ![]u8 {
    try ensureParentDirExists(runtime.io, runtime.trust_store_path);

    const trust_store = trust.Store.init(runtime.trust_store_path, runtime.io);
    var discovery = try trust_store.discoverProjectConfigAlloc(allocator, runtime.cwd_path);
    defer discovery.deinit(allocator);

    const config_path = if (discovery.untrusted) |untrusted|
        untrusted.config_path
    else if (discovery.trusted) |trusted|
        trusted.config_path
    else
        return error.ProjectConfigNotFound;

    try trust_store.trustConfig(allocator, config_path);
    return allocator.dupe(u8, config_path);
}

pub fn explainAlloc(
    allocator: std.mem.Allocator,
    runtime: Runtime,
    command_argv: []const []const u8,
) !ExplainData {
    if (command_argv.len == 0) return error.MissingCommand;

    var context = try resolver.loadContextAlloc(allocator, runtime.io, .{
        .global_config_path = runtime.global_config_path,
        .cwd_path = runtime.cwd_path,
        .trust_store_path = runtime.trust_store_path,
    });
    errdefer context.deinit(allocator);

    var resolution = try resolver.resolveAlloc(allocator, &context, command_argv, runtime.service);
    errdefer resolution.deinit(allocator);

    return .{
        .command_argv = command_argv,
        .cwd_path = runtime.cwd_path,
        .global_config_path = runtime.global_config_path,
        .context = context,
        .resolution = resolution,
    };
}

pub fn runCommand(
    allocator: std.mem.Allocator,
    runtime: Runtime,
    command_argv: []const []const u8,
) !std.process.Child.Term {
    if (command_argv.len == 0) return error.MissingCommand;

    var explain_data = try explainAlloc(allocator, runtime, command_argv);
    defer explain_data.deinit(allocator);

    var environ_map = try runtime.environ_map.clone(allocator);
    defer environ_map.deinit();

    const store = keychain.Store.init(runtime.keychain_backend, runtime.io);
    for (explain_data.resolution.bindings) |binding| {
        const value = try store.readGenericPasswordAlloc(allocator, .{
            .service = binding.service,
            .account = binding.account,
        });
        defer allocator.free(value);
        try environ_map.put(binding.env_name, value);
    }

    var child = try std.process.spawn(runtime.io, .{
        .argv = command_argv,
        .cwd = .inherit,
        .environ_map = &environ_map,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    defer child.kill(runtime.io);

    return child.wait(runtime.io);
}

pub fn renderExplain(writer: anytype, data: *const ExplainData) !void {
    try writer.print("command:", .{});
    for (data.command_argv) |arg| {
        try writer.print(" {s}", .{arg});
    }
    try writer.print("\n", .{});

    try writer.print("cwd: {s}\n", .{data.cwd_path});
    if (data.context.global_config != null and data.global_config_path != null) {
        try writer.print("global config: {s}\n", .{data.global_config_path.?});
    } else {
        try writer.print("global config: none\n", .{});
    }

    if (data.context.project_root) |path| {
        try writer.print("project root: {s}\n", .{path});
    } else {
        try writer.print("project root: none\n", .{});
    }

    if (data.context.trusted_project_config_path) |path| {
        try writer.print("project config: {s}\n", .{path});
    } else {
        try writer.print("project config: none\n", .{});
    }

    if (data.context.ignored_untrusted_project_config_path) |path| {
        try writer.print("ignored untrusted project config: {s}\n", .{path});
    }

    if (data.resolution.bindings.len == 0) {
        try writer.print("bindings: none\n", .{});
        return;
    }

    try writer.print("bindings:\n", .{});
    for (data.resolution.bindings) |binding| {
        try writer.print(
            "- {s}: service={s} account={s} lookup={s}\n",
            .{ binding.env_name, binding.service, binding.account, @tagName(binding.lookup) },
        );
    }
}

pub fn printUsage(writer: anytype, program_name: []const u8) !void {
    try writer.print(
        \\Usage:
        \\  {s} trust
        \\  {s} explain [--] <command> [args...]
        \\  {s} run -- <command> [args...]
        \\  {s} <command> [args...]
        \\
    , .{ program_name, program_name, program_name, program_name });
}

pub fn displayProgramName(arg0: []const u8) []const u8 {
    return std.fs.path.basename(arg0);
}

fn trimCommandSeparator(args: []const []const u8) []const []const u8 {
    if (args.len > 0 and std.mem.eql(u8, args[0], "--")) return args[1..];
    return args;
}

fn ensureParentDirExists(io: std.Io, path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    try std.Io.Dir.cwd().createDirPath(io, parent);
}

fn defaultConfigDirAlloc(
    allocator: std.mem.Allocator,
    environ_map: *std.process.Environ.Map,
) ![]u8 {
    if (environ_map.get("XDG_CONFIG_HOME")) |xdg_config_home| {
        return std.fs.path.join(allocator, &.{ xdg_config_home, "enject" });
    }
    if (environ_map.get("HOME")) |home| {
        return std.fs.path.join(allocator, &.{ home, ".config", "enject" });
    }
    return error.MissingHomeDirectory;
}

fn defaultKeychainBackend() keychain.Backend {
    return switch (builtin.os.tag) {
        .macos => .native,
        else => .security_cli,
    };
}
