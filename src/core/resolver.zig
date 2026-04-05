const std = @import("std");
const catalog = @import("catalog.zig");
const config = @import("../config/root.zig");
const trust = @import("../trust/root.zig");

pub const default_service = "com.github.neolee.enject";

pub const LoadedContext = struct {
    built_in_config: ?config.model.Config = null,
    global_config: ?config.model.Config = null,
    project_config: ?config.model.Config = null,
    project_root: ?[]const u8 = null,
    trusted_project_config_path: ?[]const u8 = null,
    ignored_untrusted_project_config_path: ?[]const u8 = null,

    pub fn deinit(self: *LoadedContext, allocator: std.mem.Allocator) void {
        if (self.built_in_config) |*built_in_config| built_in_config.deinit(allocator);
        if (self.global_config) |*global_config| global_config.deinit(allocator);
        if (self.project_config) |*project_config| project_config.deinit(allocator);
        if (self.project_root) |root| allocator.free(root);
        if (self.trusted_project_config_path) |path| allocator.free(path);
        if (self.ignored_untrusted_project_config_path) |path| allocator.free(path);
        self.* = .{};
    }
};

pub const ResolveOptions = struct {
    global_config_path: ?[]const u8 = null,
    cwd_path: []const u8,
    trust_store_path: []const u8,
    service: []const u8 = default_service,
};

pub const ResolvedBinding = struct {
    env_name: []const u8,
    source: Source,
    value_source: ValueSource,

    pub const ValueSource = union(enum) {
        secret: SecretRef,
        env: []const u8,
    };

    pub const Lookup = enum {
        global,
        project,
        binding_override,
    };

    pub const SecretRef = struct {
        service: []const u8,
        account: []const u8,
        lookup: Lookup,
    };
};

pub const Resolution = struct {
    bindings: []ResolvedBinding,

    pub fn deinit(self: *Resolution, allocator: std.mem.Allocator) void {
        for (self.bindings) |binding| {
            allocator.free(binding.env_name);
            switch (binding.value_source) {
                .secret => |secret| allocator.free(secret.account),
                .env => |env_name| allocator.free(env_name),
            }
        }
        allocator.free(self.bindings);
        self.* = undefined;
    }
};

pub fn loadContextAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: ResolveOptions,
) !LoadedContext {
    var result: LoadedContext = .{};
    errdefer result.deinit(allocator);

    result.built_in_config = try catalog.loadAlloc(allocator);

    if (options.global_config_path) |global_config_path| {
        result.global_config = config.parser.parseFileAlloc(allocator, io, global_config_path) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (result.global_config) |*global_config| {
            try config.validateForSource(global_config, .global);
        }
    }

    const trust_store = trust.store.Store.init(options.trust_store_path, io);
    var discovery = try trust_store.discoverProjectConfigAlloc(allocator, options.cwd_path);
    defer discovery.deinit(allocator);

    if (discovery.trusted) |trusted| {
        result.project_root = try allocator.dupe(u8, trusted.root_dir);
        result.trusted_project_config_path = try allocator.dupe(u8, trusted.config_path);
        result.project_config = try config.parser.parseFileAlloc(allocator, io, trusted.config_path);
        if (result.project_config) |*project_config| {
            try config.validateForSource(project_config, .project);
        }
    }

    if (discovery.untrusted) |untrusted| {
        result.ignored_untrusted_project_config_path = try allocator.dupe(u8, untrusted.config_path);
    }

    return result;
}

pub fn resolveAlloc(
    allocator: std.mem.Allocator,
    context: *const LoadedContext,
    argv: []const []const u8,
    service: []const u8,
) !Resolution {
    var bindings: std.ArrayList(ResolvedBinding) = .empty;
    errdefer {
        for (bindings.items) |binding| {
            allocator.free(binding.env_name);
            switch (binding.value_source) {
                .secret => |secret| allocator.free(secret.account),
                .env => |env_name| allocator.free(env_name),
            }
        }
        bindings.deinit(allocator);
    }

    if (context.built_in_config) |*built_in_config| {
        if (built_in_config.directory_rule) |directory_rule| {
            try applyInjectSet(allocator, &bindings, context, directory_rule, .built_in, service);
        }
        for (built_in_config.command_rules) |rule| {
            if (configMatchesCommandRule(&rule, argv)) {
                try applyInjectSet(allocator, &bindings, context, rule.inject, .built_in, service);
            }
        }
    }

    if (context.global_config) |*global_config| {
        if (global_config.directory_rule) |directory_rule| {
            try applyInjectSet(allocator, &bindings, context, directory_rule, .global_config, service);
        }
        for (global_config.command_rules) |rule| {
            if (configMatchesCommandRule(&rule, argv)) {
                try applyInjectSet(allocator, &bindings, context, rule.inject, .global_config, service);
            }
        }
    }

    if (context.project_config) |*project_config| {
        if (project_config.directory_rule) |directory_rule| {
            try applyInjectSet(allocator, &bindings, context, directory_rule, .project_config, service);
        }
        for (project_config.command_rules) |rule| {
            if (configMatchesCommandRule(&rule, argv)) {
                try applyInjectSet(allocator, &bindings, context, rule.inject, .project_config, service);
            }
        }
    }

    return .{
        .bindings = try bindings.toOwnedSlice(allocator),
    };
}

fn applyInjectSet(
    allocator: std.mem.Allocator,
    bindings: *std.ArrayList(ResolvedBinding),
    context: *const LoadedContext,
    inject: config.model.InjectSet,
    source: Source,
    service: []const u8,
) !void {
    for (inject.groups) |group_name| {
        const group = lookupGroup(context, group_name) orelse return error.UnknownEnvGroup;
        for (group.global) |env_name| {
            try addBinding(allocator, bindings, try resolveBindingAlloc(allocator, context, source, env_name, .global, service));
        }
        for (group.project) |env_name| {
            try addBinding(allocator, bindings, try resolveBindingAlloc(allocator, context, source, env_name, .project, service));
        }
    }
    for (inject.global) |env_name| {
        try addBinding(allocator, bindings, try resolveBindingAlloc(allocator, context, source, env_name, .global, service));
    }
    for (inject.project) |env_name| {
        try addBinding(allocator, bindings, try resolveBindingAlloc(allocator, context, source, env_name, .project, service));
    }
}

fn addBinding(
    allocator: std.mem.Allocator,
    bindings: *std.ArrayList(ResolvedBinding),
    binding: ResolvedBinding,
) !void {
    for (bindings.items) |*existing| {
        if (!std.mem.eql(u8, existing.env_name, binding.env_name)) continue;
        if (bindingsEquivalent(existing, &binding)) {
            if (sourceRank(binding.source) >= sourceRank(existing.source)) {
                existing.source = binding.source;
            }
            allocator.free(binding.env_name);
            freeBindingValueSource(allocator, binding.value_source);
            return;
        }
        if (existing.source == .built_in and binding.source != .built_in) {
            allocator.free(existing.env_name);
            freeBindingValueSource(allocator, existing.value_source);
            existing.* = binding;
            return;
        }
        if (binding.source == .built_in and existing.source != .built_in) {
            allocator.free(binding.env_name);
            freeBindingValueSource(allocator, binding.value_source);
            return;
        }
        allocator.free(binding.env_name);
        freeBindingValueSource(allocator, binding.value_source);
        return error.BindingConflict;
    }

    try bindings.append(allocator, binding);
}

const Source = enum {
    built_in,
    global_config,
    project_config,
};

fn resolveBindingAlloc(
    allocator: std.mem.Allocator,
    context: *const LoadedContext,
    source: Source,
    env_name: []const u8,
    scope: ResolvedBinding.Lookup,
    service: []const u8,
) !ResolvedBinding {
    if (lookupOverride(context, env_name)) |override| {
        switch (override.binding.source) {
            .account => |account| return .{
                .env_name = try allocator.dupe(u8, env_name),
                .source = override.source,
                .value_source = .{
                    .secret = .{
                        .service = service,
                        .account = try allocator.dupe(u8, account),
                        .lookup = .binding_override,
                    },
                },
            },
            .env => |target_env| return .{
                .env_name = try allocator.dupe(u8, env_name),
                .source = override.source,
                .value_source = .{
                    .env = try allocator.dupe(u8, target_env),
                },
            },
        }
    }

    const canonical_key = try canonicalizeEnvNameAlloc(allocator, env_name);
    defer allocator.free(canonical_key);

    const account = switch (scope) {
        .global, .binding_override => try allocator.dupe(u8, canonical_key),
        .project => blk: {
            const project_name = projectName(context) orelse return error.MissingProjectName;
            break :blk try std.fs.path.join(allocator, &.{ project_name, canonical_key });
        },
    };

    return .{
        .env_name = try allocator.dupe(u8, env_name),
        .source = source,
        .value_source = .{
            .secret = .{
                .service = service,
                .account = account,
                .lookup = scope,
            },
        },
    };
}

const OverrideResult = struct {
    binding: config.model.Binding,
    source: Source,
};

fn lookupOverride(
    context: *const LoadedContext,
    env_name: []const u8,
) ?OverrideResult {
    if (context.project_config) |project_config| {
        if (project_config.getBinding(env_name)) |binding| {
            return .{
                .binding = binding,
                .source = .project_config,
            };
        }
    }
    if (context.global_config) |global_config| {
        if (global_config.getBinding(env_name)) |binding| {
            return .{
                .binding = binding,
                .source = .global_config,
            };
        }
    }
    if (context.built_in_config) |built_in_config| {
        if (built_in_config.getBinding(env_name)) |binding| {
            return .{
                .binding = binding,
                .source = .built_in,
            };
        }
    }
    return null;
}

fn lookupGroup(
    context: *const LoadedContext,
    group_name: []const u8,
) ?config.model.Group {
    if (context.project_config) |project_config| {
        if (project_config.getGroup(group_name)) |group| return group;
    }
    if (context.global_config) |global_config| {
        if (global_config.getGroup(group_name)) |group| return group;
    }
    if (context.built_in_config) |built_in_config| {
        if (built_in_config.getGroup(group_name)) |group| return group;
    }
    return null;
}

fn projectName(context: *const LoadedContext) ?[]const u8 {
    if (context.project_config) |project_config| {
        return project_config.project_name;
    }
    return null;
}

fn configMatchesCommandRule(rule: *const config.model.CommandRule, argv: []const []const u8) bool {
    if (rule.match.argv) |expected_argv| {
        if (!matchesExact(expected_argv, argv)) return false;
    }
    if (rule.match.argv_prefix) |expected_prefix| {
        if (!matchesPrefix(expected_prefix, argv)) return false;
    }
    return true;
}

fn sourceRank(source: Source) u8 {
    return switch (source) {
        .built_in => 0,
        .global_config => 1,
        .project_config => 2,
    };
}

pub fn sourceName(source: Source) []const u8 {
    return switch (source) {
        .built_in => "built-in",
        .global_config => "global config",
        .project_config => "project config",
    };
}

fn bindingsEquivalent(left: *const ResolvedBinding, right: *const ResolvedBinding) bool {
    return switch (left.value_source) {
        .secret => |left_secret| switch (right.value_source) {
            .secret => |right_secret|
                std.mem.eql(u8, left_secret.service, right_secret.service) and
                std.mem.eql(u8, left_secret.account, right_secret.account),
            .env => false,
        },
        .env => |left_env| switch (right.value_source) {
            .secret => false,
            .env => |right_env| std.mem.eql(u8, left_env, right_env),
        },
    };
}

fn freeBindingValueSource(allocator: std.mem.Allocator, value_source: ResolvedBinding.ValueSource) void {
    switch (value_source) {
        .secret => |secret| allocator.free(secret.account),
        .env => |env_name| allocator.free(env_name),
    }
}

pub fn valueSourceDescription(
    buffer: []u8,
    binding: *const ResolvedBinding,
) ![]const u8 {
    return switch (binding.value_source) {
        .secret => |secret| std.fmt.bufPrint(buffer, "{s}/{s}", .{ secret.service, secret.account }),
        .env => |env_name| std.fmt.bufPrint(buffer, "env({s})", .{env_name}),
    };
}

pub fn lookupName(binding: *const ResolvedBinding) []const u8 {
    return switch (binding.value_source) {
        .secret => |secret| @tagName(secret.lookup),
        .env => "env",
    };
}

fn matchesExact(expected: [][]const u8, argv: []const []const u8) bool {
    if (expected.len != argv.len) return false;
    for (expected, argv) |left, right| {
        if (!std.mem.eql(u8, left, right)) return false;
    }
    return true;
}

fn matchesPrefix(expected: [][]const u8, argv: []const []const u8) bool {
    if (expected.len > argv.len) return false;
    for (expected, 0..) |left, index| {
        if (!std.mem.eql(u8, left, argv[index])) return false;
    }
    return true;
}

pub fn canonicalizeEnvNameAlloc(allocator: std.mem.Allocator, env_name: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var last_was_separator = false;
    for (env_name) |char| {
        const normalized = switch (char) {
            'A'...'Z' => char + ('a' - 'A'),
            'a'...'z', '0'...'9' => char,
            else => '_',
        };

        if (normalized == '_') {
            if (out.items.len == 0 or last_was_separator) continue;
            last_was_separator = true;
            try out.append(allocator, normalized);
            continue;
        }

        last_was_separator = false;
        try out.append(allocator, normalized);
    }

    if (out.items.len > 0 and out.items[out.items.len - 1] == '_') {
        _ = out.pop();
    }

    return out.toOwnedSlice(allocator);
}
