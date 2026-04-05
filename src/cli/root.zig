const builtin = @import("builtin");
const std = @import("std");
const catalog = @import("../core/catalog.zig");
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
    catalog_show,
    trust,
    explain: ExplainCommand,
    run: RunCommand,
    secret: SecretCommand,
    import_env: ImportCommand,
};

pub const ExplainCommand = struct {
    command_argv: []const []const u8,
    check: bool = false,
};

pub const RunCommand = struct {
    command_argv: []const []const u8,
    verbose: bool = false,
};

pub const SecretCommand = union(enum) {
    put: SecretPut,
    ls,
    rm: []const u8,
};

pub const SecretPut = struct {
    name: []const u8,
    value: ?[]const u8 = null,
};

pub const ImportCommand = struct {
    file_path: []const u8,
    project_name: ?[]const u8 = null,
    env_key: ?[]const u8 = null,
};

pub const ImportedSecret = struct {
    env_name: []const u8,
    account: []const u8,
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

pub const DoctorBindingStatus = enum {
    present,
    missing,
};

pub const DoctorData = struct {
    command_argv: []const []const u8,
    cwd_path: []const u8,
    global_config_path: ?[]const u8,
    keychain_backend: keychain.Backend,
    context: resolver.LoadedContext,
    resolution: resolver.Resolution,
    binding_statuses: []DoctorBindingStatus,

    pub fn deinit(self: *DoctorData, allocator: std.mem.Allocator) void {
        self.context.deinit(allocator);
        self.resolution.deinit(allocator);
        allocator.free(self.binding_statuses);
        self.* = undefined;
    }
};

pub const MissingSecret = struct {
    env_name: []const u8,
    detail: []const u8,

    pub fn deinit(self: *MissingSecret, allocator: std.mem.Allocator) void {
        allocator.free(self.env_name);
        allocator.free(self.detail);
        self.* = undefined;
    }
};

pub const RunResult = struct {
    term: std.process.Child.Term,
    missing_secrets: []MissingSecret,

    pub fn deinit(self: *RunResult, allocator: std.mem.Allocator) void {
        for (self.missing_secrets) |*missing_secret| {
            missing_secret.deinit(allocator);
        }
        allocator.free(self.missing_secrets);
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

    const keychain_backend = try resolveKeychainBackend(init.environ_map);

    return .{
        .io = init.io,
        .environ_map = init.environ_map,
        .cwd_path = cwd_path,
        .global_config_path = global_config_path,
        .trust_store_path = trust_store_path,
        .keychain_backend = keychain_backend,
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

    var verbose = false;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
            continue;
        }
        break;
    }

    if (index >= args.len) return .help;

    const verb = args[index];
    if (std.mem.eql(u8, verb, "-h") or std.mem.eql(u8, verb, "--help") or std.mem.eql(u8, verb, "help")) {
        if (verbose) return error.UnexpectedArgument;
        return .help;
    }
    if (std.mem.eql(u8, verb, "trust")) {
        if (verbose or args.len != index + 1) return error.UnexpectedArgument;
        return .trust;
    }
    if (std.mem.eql(u8, verb, "catalog")) {
        if (verbose) return error.UnexpectedArgument;
        if (args.len != index + 2) return error.UnexpectedArgument;
        if (!std.mem.eql(u8, args[index + 1], "show")) return error.UnknownSubcommand;
        return .catalog_show;
    }
    if (std.mem.eql(u8, verb, "explain")) {
        if (verbose) return error.UnexpectedArgument;
        return .{ .explain = try parseExplainCommand(args[index + 1 ..], false) };
    }
    if (std.mem.eql(u8, verb, "doctor")) {
        if (verbose) return error.UnexpectedArgument;
        return .{ .explain = try parseExplainCommand(args[index + 1 ..], true) };
    }
    if (std.mem.eql(u8, verb, "run")) {
        return .{ .run = try parseRunCommand(args[index + 1 ..], verbose) };
    }
    if (std.mem.eql(u8, verb, "secret")) {
        if (verbose) return error.UnexpectedArgument;
        return .{ .secret = try parseSecretCommand(args[index + 1 ..]) };
    }
    if (std.mem.eql(u8, verb, "import")) {
        if (verbose) return error.UnexpectedArgument;
        return .{ .import_env = try parseImportCommand(args[index + 1 ..]) };
    }
    if (std.mem.eql(u8, verb, "--")) {
        return .{ .run = .{
            .command_argv = args[index + 1 ..],
            .verbose = verbose,
        } };
    }
    return .{ .run = .{
        .command_argv = args[index..],
        .verbose = verbose,
    } };
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

pub fn doctorAlloc(
    allocator: std.mem.Allocator,
    runtime: Runtime,
    command_argv: []const []const u8,
) !DoctorData {
    var context = try resolver.loadContextAlloc(allocator, runtime.io, .{
        .global_config_path = runtime.global_config_path,
        .cwd_path = runtime.cwd_path,
        .trust_store_path = runtime.trust_store_path,
    });
    errdefer context.deinit(allocator);

    var resolution = try resolver.resolveAlloc(allocator, &context, command_argv, runtime.service);
    errdefer resolution.deinit(allocator);
    const binding_statuses = try allocator.alloc(DoctorBindingStatus, resolution.bindings.len);
    errdefer allocator.free(binding_statuses);
    const resolved_values = try resolveBindingValuesAlloc(allocator, runtime, &resolution);
    defer deinitResolvedValues(allocator, resolved_values);

    for (resolved_values, 0..) |maybe_value, index| {
        binding_statuses[index] = if (maybe_value != null) .present else .missing;
    }

    return .{
        .command_argv = command_argv,
        .cwd_path = runtime.cwd_path,
        .global_config_path = runtime.global_config_path,
        .keychain_backend = runtime.keychain_backend,
        .context = context,
        .resolution = resolution,
        .binding_statuses = binding_statuses,
    };
}

pub fn putSecret(
    allocator: std.mem.Allocator,
    runtime: Runtime,
    name: []const u8,
    value: []const u8,
) ![]u8 {
    const account = try secretAccountFromNameAlloc(allocator, name);
    errdefer allocator.free(account);

    const store = keychain.Store.init(runtime.keychain_backend, runtime.io);
    try store.writeGenericPassword(allocator, .{
        .service = runtime.service,
        .account = account,
    }, value);

    return account;
}

pub fn removeSecret(
    allocator: std.mem.Allocator,
    runtime: Runtime,
    name: []const u8,
) ![]u8 {
    const account = try secretAccountFromNameAlloc(allocator, name);
    errdefer allocator.free(account);

    const store = keychain.Store.init(runtime.keychain_backend, runtime.io);
    try store.deleteGenericPassword(allocator, .{
        .service = runtime.service,
        .account = account,
    });

    return account;
}

pub fn listSecretsAlloc(
    allocator: std.mem.Allocator,
    runtime: Runtime,
) ![][]u8 {
    const store = keychain.Store.init(runtime.keychain_backend, runtime.io);
    return store.listGenericPasswordAccountsAlloc(allocator, runtime.service);
}

pub fn importSecretsAlloc(
    allocator: std.mem.Allocator,
    runtime: Runtime,
    command: ImportCommand,
) ![]ImportedSecret {
    const file_data = try std.Io.Dir.cwd().readFileAlloc(runtime.io, command.file_path, allocator, .unlimited);
    defer allocator.free(file_data);

    var imported: std.ArrayList(ImportedSecret) = .empty;
    errdefer {
        for (imported.items) |item| {
            allocator.free(item.env_name);
            allocator.free(item.account);
        }
        imported.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, file_data, '\n');
    while (lines.next()) |raw_line| {
        const parsed = parseEnvAssignment(raw_line) orelse continue;
        if (command.env_key) |env_key| {
            if (!std.mem.eql(u8, parsed.env_name, env_key)) continue;
        }

        const account = try accountFromEnvNameAlloc(allocator, parsed.env_name, command.project_name);
        errdefer allocator.free(account);

        const store = keychain.Store.init(runtime.keychain_backend, runtime.io);
        try store.writeGenericPassword(allocator, .{
            .service = runtime.service,
            .account = account,
        }, parsed.value);

        try imported.append(allocator, .{
            .env_name = try allocator.dupe(u8, parsed.env_name),
            .account = account,
        });
    }

    return imported.toOwnedSlice(allocator);
}

pub fn runCommand(
    allocator: std.mem.Allocator,
    runtime: Runtime,
    command_argv: []const []const u8,
    verbose: bool,
    warning_writer: anytype,
) !RunResult {
    if (command_argv.len == 0) return error.MissingCommand;

    var explain_data = try explainAlloc(allocator, runtime, command_argv);
    defer explain_data.deinit(allocator);

    var environ_map = try runtime.environ_map.clone(allocator);
    defer environ_map.deinit();

    var missing_secrets: std.ArrayList(MissingSecret) = .empty;
    errdefer {
        for (missing_secrets.items) |*missing_secret| {
            missing_secret.deinit(allocator);
        }
        missing_secrets.deinit(allocator);
    }

    const resolved_values = try resolveBindingValuesAlloc(allocator, runtime, &explain_data.resolution);
    defer deinitResolvedValues(allocator, resolved_values);

    for (explain_data.resolution.bindings, resolved_values) |binding, maybe_value| {
        if (maybe_value) |value| {
            try environ_map.put(binding.env_name, value);
            continue;
        }
        var detail_buffer: [512]u8 = undefined;
        try missing_secrets.append(allocator, .{
            .env_name = try allocator.dupe(u8, binding.env_name),
            .detail = try allocator.dupe(u8, try resolver.valueSourceDescription(&detail_buffer, &binding)),
        });
    }

    if (verbose and missing_secrets.items.len > 0) {
        for (missing_secrets.items) |missing_secret| {
            try warning_writer.print(
                "warning: value not available for {s} ({s}); skipping injection\n",
                .{ missing_secret.env_name, missing_secret.detail },
            );
        }
        try warning_writer.flush();
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

    return .{
        .term = try child.wait(runtime.io),
        .missing_secrets = try missing_secrets.toOwnedSlice(allocator),
    };
}

pub fn renderExplain(writer: anytype, data: *const ExplainData) !void {
    try writer.print("Command:", .{});
    for (data.command_argv) |arg| {
        try writer.print(" {s}", .{arg});
    }
    try writer.print("\n", .{});

    try writer.print("Resolution mode: config and rule resolution only (no secrets read)\n", .{});
    try writer.print("\nContext\n", .{});
    try writer.print("  cwd: {s}\n", .{data.cwd_path});
    if (data.context.global_config != null and data.global_config_path != null) {
        try writer.print("  global config: {s}\n", .{data.global_config_path.?});
    } else {
        try writer.print("  global config: none\n", .{});
    }

    if (data.context.project_root) |path| {
        try writer.print("  project root: {s}\n", .{path});
    } else {
        try writer.print("  project root: none\n", .{});
    }

    if (data.context.trusted_project_config_path) |path| {
        try writer.print("  project config: {s}\n", .{path});
    } else {
        try writer.print("  project config: none\n", .{});
    }

    if (data.context.ignored_untrusted_project_config_path) |path| {
        try writer.print("  ignored untrusted project config: {s}\n", .{path});
    }

    try writer.print("\nBindings\n", .{});
    if (data.resolution.bindings.len == 0) {
        try writer.print("  none\n", .{});
        return;
    }

    for (data.resolution.bindings) |binding| {
        var detail_buffer: [512]u8 = undefined;
        try writer.print(
            "  {s} -> {s} ({s}, {s})\n",
            .{ binding.env_name, try resolver.valueSourceDescription(&detail_buffer, &binding), resolver.sourceName(binding.source), resolver.lookupName(&binding) },
        );
    }
}

pub fn renderDoctor(writer: anytype, data: *const DoctorData) !void {
    try writer.print("Backend: {s}\n", .{backendName(data.keychain_backend)});
    if (data.command_argv.len == 0) {
        try writer.print("Command: none (directory-scoped rules only)\n", .{});
    } else {
        try writer.print("Command:", .{});
        for (data.command_argv) |arg| {
            try writer.print(" {s}", .{arg});
        }
        try writer.print("\n", .{});
    }

    try writer.print("Resolution mode: config, rule, and secret availability check (no values shown)\n", .{});
    try writer.print("\nContext\n", .{});
    try writer.print("  cwd: {s}\n", .{data.cwd_path});
    if (data.context.global_config != null and data.global_config_path != null) {
        try writer.print("  global config: {s}\n", .{data.global_config_path.?});
    } else {
        try writer.print("  global config: none\n", .{});
    }
    if (data.context.project_root) |path| {
        try writer.print("  project root: {s}\n", .{path});
    } else {
        try writer.print("  project root: none\n", .{});
    }
    if (data.context.trusted_project_config_path) |path| {
        try writer.print("  project config: {s}\n", .{path});
    } else {
        try writer.print("  project config: none\n", .{});
    }
    if (data.context.ignored_untrusted_project_config_path) |path| {
        try writer.print("  ignored untrusted project config: {s}\n", .{path});
    }

    try writer.print("\nBindings\n", .{});
    if (data.resolution.bindings.len == 0) {
        try writer.print("  none\n", .{});
        return;
    }

    for (data.resolution.bindings, data.binding_statuses) |binding, status| {
        var detail_buffer: [512]u8 = undefined;
        try writer.print(
            "  {s} -> {s} ({s}, {s}, {s})\n",
            .{ binding.env_name, try resolver.valueSourceDescription(&detail_buffer, &binding), resolver.sourceName(binding.source), resolver.lookupName(&binding), @tagName(status) },
        );
    }
}

pub fn printUsage(writer: anytype, program_name: []const u8) !void {
    try writer.print(
        \\Usage:
        \\  {s} catalog show
        \\  {s} trust
        \\  {s} secret put <name> [--value <value>]
        \\  {s} secret ls
        \\  {s} secret rm <name>
        \\  {s} import <key-file> [--project <project-name>] [--key <env-key>]
        \\  {s} explain [--check] [--] [command] [args...]
        \\  {s} [--verbose] run [--verbose] -- <command> [args...]
        \\  {s} [--verbose] <command> [args...]
        \\
    , .{ program_name, program_name, program_name, program_name, program_name, program_name, program_name, program_name, program_name });
}

pub fn renderCatalog(writer: anytype) !void {
    try writer.writeAll(catalog.text());
    if (catalog.text().len == 0 or catalog.text()[catalog.text().len - 1] != '\n') {
        try writer.writeByte('\n');
    }
}

pub fn displayProgramName(arg0: []const u8) []const u8 {
    return std.fs.path.basename(arg0);
}

fn trimCommandSeparator(args: []const []const u8) []const []const u8 {
    if (args.len > 0 and std.mem.eql(u8, args[0], "--")) return args[1..];
    return args;
}

fn parseExplainCommand(args: []const []const u8, default_check: bool) !ExplainCommand {
    var check = default_check;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--check")) {
            check = true;
            continue;
        }
        break;
    }

    return .{
        .command_argv = trimCommandSeparator(args[index..]),
        .check = check,
    };
}

fn parseRunCommand(args: []const []const u8, initial_verbose: bool) !RunCommand {
    var verbose = initial_verbose;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
            continue;
        }
        break;
    }

    return .{
        .command_argv = trimCommandSeparator(args[index..]),
        .verbose = verbose,
    };
}

fn parseSecretCommand(args: []const []const u8) !SecretCommand {
    if (args.len == 0) return error.MissingSubcommand;

    const verb = args[0];
    if (std.mem.eql(u8, verb, "ls")) {
        if (args.len != 1) return error.UnexpectedArgument;
        return .ls;
    }
    if (std.mem.eql(u8, verb, "rm")) {
        if (args.len != 2) return error.UnexpectedArgument;
        return .{ .rm = args[1] };
    }
    if (std.mem.eql(u8, verb, "put")) {
        if (args.len == 2) {
            return .{ .put = .{
                .name = args[1],
                .value = null,
            } };
        }
        if (args.len != 4) return error.UnexpectedArgument;
        if (!std.mem.eql(u8, args[2], "--value")) return error.UnexpectedArgument;
        return .{ .put = .{
            .name = args[1],
            .value = args[3],
        } };
    }
    return error.UnknownSubcommand;
}

fn parseImportCommand(args: []const []const u8) !ImportCommand {
    if (args.len == 0) return error.MissingCommand;

    var command: ImportCommand = .{
        .file_path = args[0],
    };

    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--project")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            command.project_name = args[index];
            continue;
        }
        if (std.mem.eql(u8, arg, "--key")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            command.env_key = args[index];
            continue;
        }
        return error.UnexpectedArgument;
    }

    return command;
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

pub fn resolveKeychainBackend(environ_map: *std.process.Environ.Map) !keychain.Backend {
    const override = environ_map.get("ENJECT_KEYCHAIN_BACKEND") orelse return defaultKeychainBackend();
    if (std.mem.eql(u8, override, "native")) return .native;
    if (std.mem.eql(u8, override, "security_cli")) return .security_cli;
    return error.InvalidKeychainBackend;
}

fn defaultKeychainBackend() keychain.Backend {
    return switch (builtin.os.tag) {
        .macos => .native,
        else => .security_cli,
    };
}

fn backendName(backend: keychain.Backend) []const u8 {
    return switch (backend) {
        .native => "native",
        .security_cli => "security_cli",
    };
}

const ResolveState = enum {
    unresolved,
    resolving,
    resolved,
    missing,
};

fn resolveBindingValuesAlloc(
    allocator: std.mem.Allocator,
    runtime: Runtime,
    resolution: *const resolver.Resolution,
) ![]?[]u8 {
    const values = try allocator.alloc(?[]u8, resolution.bindings.len);
    errdefer allocator.free(values);
    const states = try allocator.alloc(ResolveState, resolution.bindings.len);
    defer allocator.free(states);

    for (values) |*slot| slot.* = null;
    for (states) |*state| state.* = .unresolved;

    for (resolution.bindings, 0..) |_, index| {
        _ = try resolveBindingValueAtIndexAlloc(allocator, runtime, resolution, values, states, index);
    }

    return values;
}

fn deinitResolvedValues(allocator: std.mem.Allocator, values: []?[]u8) void {
    for (values) |maybe_value| {
        if (maybe_value) |value| allocator.free(value);
    }
    allocator.free(values);
}

fn resolveBindingValueAtIndexAlloc(
    allocator: std.mem.Allocator,
    runtime: Runtime,
    resolution: *const resolver.Resolution,
    values: []?[]u8,
    states: []ResolveState,
    index: usize,
) anyerror!?[]u8 {
    return switch (states[index]) {
        .resolved => values[index].?,
        .missing => null,
        .resolving => error.BindingCycle,
        .unresolved => blk: {
            states[index] = .resolving;
            const binding = resolution.bindings[index];
            const value = switch (binding.value_source) {
                .secret => |secret| resolveSecretValueAlloc(allocator, runtime, secret) catch |err| switch (err) {
                    error.NotFound => null,
                    else => return err,
                },
                .env => |target_env_name| try resolveEnvAliasValueAlloc(allocator, runtime, resolution, values, states, target_env_name),
            };

            if (value) |resolved_value| {
                values[index] = resolved_value;
                states[index] = .resolved;
                break :blk resolved_value;
            }

            states[index] = .missing;
            break :blk null;
        },
    };
}

fn resolveSecretValueAlloc(
    allocator: std.mem.Allocator,
    runtime: Runtime,
    secret: resolver.ResolvedBinding.SecretRef,
) anyerror![]u8 {
    const store = keychain.Store.init(runtime.keychain_backend, runtime.io);
    return store.readGenericPasswordAlloc(allocator, .{
        .service = secret.service,
        .account = secret.account,
    });
}

fn resolveEnvAliasValueAlloc(
    allocator: std.mem.Allocator,
    runtime: Runtime,
    resolution: *const resolver.Resolution,
    values: []?[]u8,
    states: []ResolveState,
    target_env_name: []const u8,
) anyerror!?[]u8 {
    for (resolution.bindings, 0..) |binding, index| {
        if (!std.mem.eql(u8, binding.env_name, target_env_name)) continue;
        if (try resolveBindingValueAtIndexAlloc(allocator, runtime, resolution, values, states, index)) |resolved_value| {
            return try allocator.dupe(u8, resolved_value);
        }
        break;
    }

    if (runtime.environ_map.get(target_env_name)) |inherited_value| {
        return try allocator.dupe(u8, inherited_value);
    }

    return null;
}

fn secretAccountFromNameAlloc(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, name, '/')) |_| {
        return allocator.dupe(u8, name);
    }
    return resolver.canonicalizeEnvNameAlloc(allocator, name);
}

fn accountFromEnvNameAlloc(
    allocator: std.mem.Allocator,
    env_name: []const u8,
    project_name: ?[]const u8,
) ![]u8 {
    const canonical = try resolver.canonicalizeEnvNameAlloc(allocator, env_name);
    defer allocator.free(canonical);

    if (project_name) |project| {
        return std.fs.path.join(allocator, &.{ project, canonical });
    }
    return allocator.dupe(u8, canonical);
}

const ParsedEnvAssignment = struct {
    env_name: []const u8,
    value: []const u8,
};

fn parseEnvAssignment(line: []const u8) ?ParsedEnvAssignment {
    var trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0 or trimmed[0] == '#') return null;

    if (std.mem.startsWith(u8, trimmed, "export ")) {
        trimmed = std.mem.trim(u8, trimmed["export ".len..], " \t");
    }

    const eq_index = std.mem.indexOfScalar(u8, trimmed, '=') orelse return null;
    const env_name = std.mem.trim(u8, trimmed[0..eq_index], " \t");
    if (env_name.len == 0) return null;

    var value = std.mem.trim(u8, trimmed[eq_index + 1 ..], " \t");
    if (value.len >= 2) {
        const first = value[0];
        const last = value[value.len - 1];
        if ((first == '"' and last == '"') or (first == '\'' and last == '\'')) {
            value = value[1 .. value.len - 1];
        }
    }

    return .{
        .env_name = env_name,
        .value = value,
    };
}

pub fn promptSecretValueAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    writer: anytype,
    secret_name: []const u8,
) ![]u8 {
    try writer.print("Enter value for {s}: ", .{secret_name});
    try writer.flush();

    const stdin = std.Io.File.stdin();
    const original_termios = try std.posix.tcgetattr(stdin.handle);
    var hidden_termios = original_termios;
    hidden_termios.lflag.ECHO = false;
    try std.posix.tcsetattr(stdin.handle, .NOW, hidden_termios);
    defer std.posix.tcsetattr(stdin.handle, .NOW, original_termios) catch {};

    var input_buffer: [4096]u8 = undefined;
    var stdin_reader = stdin.reader(io, &input_buffer);
    const line = (try stdin_reader.interface.takeDelimiter('\n')) orelse return error.MissingValue;
    try writer.print("\n", .{});
    try writer.flush();

    const trimmed = std.mem.trim(u8, line, "\r");
    if (trimmed.len == 0) return error.MissingValue;
    return allocator.dupe(u8, trimmed);
}
