const std = @import("std");
const config = @import("../config/root.zig");
const trust = @import("../trust/root.zig");

pub const default_service = "com.github.neolee.enject";

pub const LoadedContext = struct {
    global_config: ?config.model.Config = null,
    project_config: ?config.model.Config = null,
    project_root: ?[]const u8 = null,
    trusted_project_config_path: ?[]const u8 = null,
    ignored_untrusted_project_config_path: ?[]const u8 = null,

    pub fn deinit(self: *LoadedContext, allocator: std.mem.Allocator) void {
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
    service: []const u8,
    account: []const u8,
    lookup: Lookup,

    pub const Lookup = enum {
        global,
        project,
        binding_override,
    };
};

pub const Resolution = struct {
    bindings: []ResolvedBinding,

    pub fn deinit(self: *Resolution, allocator: std.mem.Allocator) void {
        for (self.bindings) |binding| {
            allocator.free(binding.env_name);
            allocator.free(binding.account);
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

    if (options.global_config_path) |global_config_path| {
        result.global_config = try config.parser.parseFileAlloc(allocator, io, global_config_path);
    }

    const trust_store = trust.store.Store.init(options.trust_store_path, io);
    var discovery = try trust_store.discoverProjectConfigAlloc(allocator, options.cwd_path);
    defer discovery.deinit(allocator);

    if (discovery.trusted) |trusted| {
        result.project_root = try allocator.dupe(u8, trusted.root_dir);
        result.trusted_project_config_path = try allocator.dupe(u8, trusted.config_path);
        result.project_config = try config.parser.parseFileAlloc(allocator, io, trusted.config_path);
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
            allocator.free(binding.account);
        }
        bindings.deinit(allocator);
    }

    if (context.global_config) |*global_config| {
        if (global_config.directory_rule) |directory_rule| {
            try applyInjectSet(allocator, &bindings, context, directory_rule, .global_config, service);
        }
        for (global_config.command_rules) |rule| {
            if (matchesCommandRule(&rule, argv)) {
                try applyInjectSet(allocator, &bindings, context, rule.inject, .global_config, service);
            }
        }
    }

    if (context.project_config) |*project_config| {
        if (project_config.directory_rule) |directory_rule| {
            try applyInjectSet(allocator, &bindings, context, directory_rule, .project_config, service);
        }
        for (project_config.command_rules) |rule| {
            if (matchesCommandRule(&rule, argv)) {
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
    for (bindings.items) |existing| {
        if (!std.mem.eql(u8, existing.env_name, binding.env_name)) continue;
        if (std.mem.eql(u8, existing.service, binding.service) and std.mem.eql(u8, existing.account, binding.account)) {
            allocator.free(binding.env_name);
            allocator.free(binding.account);
            return;
        }
        allocator.free(binding.env_name);
        allocator.free(binding.account);
        return error.BindingConflict;
    }

    try bindings.append(allocator, binding);
}

const Source = enum {
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
    if (lookupOverride(context, source, env_name)) |binding| {
        return .{
            .env_name = try allocator.dupe(u8, env_name),
            .service = service,
            .account = try allocator.dupe(u8, binding.account),
            .lookup = .binding_override,
        };
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
        .service = service,
        .account = account,
        .lookup = scope,
    };
}

fn lookupOverride(
    context: *const LoadedContext,
    source: Source,
    env_name: []const u8,
) ?config.model.Binding {
    return switch (source) {
        .global_config => if (context.global_config) |global_config|
            global_config.getBinding(env_name)
        else
            null,
        .project_config => blk: {
            if (context.project_config) |project_config| {
                if (project_config.getBinding(env_name)) |binding| break :blk binding;
            }
            if (context.global_config) |global_config| {
                if (global_config.getBinding(env_name)) |binding| break :blk binding;
            }
            break :blk null;
        },
    };
}

fn projectName(context: *const LoadedContext) ?[]const u8 {
    if (context.project_config) |project_config| {
        return project_config.project_name;
    }
    return null;
}

fn matchesCommandRule(rule: *const config.model.CommandRule, argv: []const []const u8) bool {
    if (rule.match.argv) |expected_argv| {
        if (!matchesExact(expected_argv, argv)) return false;
    }
    if (rule.match.argv_prefix) |expected_prefix| {
        if (!matchesPrefix(expected_prefix, argv)) return false;
    }
    return true;
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

fn canonicalizeEnvNameAlloc(allocator: std.mem.Allocator, env_name: []const u8) ![]u8 {
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
