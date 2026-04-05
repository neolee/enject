const std = @import("std");
const toml = @import("toml");
const model = @import("model.zig");

pub fn parseFileAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) !model.Config {
    var parser = toml.Parser(RawConfig).init(allocator);
    defer parser.deinit();

    const parsed = try parser.parseFile(io, path);
    defer parsed.deinit();

    return convertConfigAlloc(allocator, parsed.value);
}

pub fn parseSliceAlloc(allocator: std.mem.Allocator, input: []const u8) !model.Config {
    var parser = toml.Parser(RawConfig).init(allocator);
    defer parser.deinit();

    const parsed = try parser.parseString(input);
    defer parsed.deinit();

    return convertConfigAlloc(allocator, parsed.value);
}

const RawBinding = struct {
    account: ?[]const u8 = null,
    env: ?[]const u8 = null,
};

const RawGroup = struct {
    global: ?[]const []const u8 = null,
    project: ?[]const []const u8 = null,
};

const RawInjectSet = struct {
    groups: ?[]const []const u8 = null,
    global: ?[]const []const u8 = null,
    project: ?[]const []const u8 = null,
};

const RawCommandMatch = struct {
    argv: ?[]const []const u8 = null,
    argv_prefix: ?[]const []const u8 = null,
};

const RawCommandRule = struct {
    match: RawCommandMatch = .{},
    inject: RawInjectSet = .{},
};

const RawProject = struct {
    name: []const u8,
};

const RawRules = struct {
    directory: ?RawInjectSet = null,
    command: ?[]const RawCommandRule = null,
};

const RawConfig = struct {
    version: u32 = 1,
    project: ?RawProject = null,
    rules: ?RawRules = null,
    groups: ?toml.HashMap(RawGroup) = null,
    bindings: ?toml.HashMap(RawBinding) = null,
};

fn convertConfigAlloc(allocator: std.mem.Allocator, raw: RawConfig) !model.Config {
    var config: model.Config = .{
        .version = raw.version,
    };
    errdefer config.deinit(allocator);

    if (raw.project) |project| {
        config.project_name = try allocator.dupe(u8, project.name);
    }

    if (raw.rules) |rules| {
        if (rules.directory) |directory| {
            config.directory_rule = try convertInjectSetAlloc(allocator, directory);
        }
        if (rules.command) |command_rules| {
            config.command_rules = try convertCommandRulesAlloc(allocator, command_rules);
        }
    }

    if (raw.groups) |raw_groups| {
        var iter = raw_groups.map.iterator();
        while (iter.next()) |entry| {
            const key_copy = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(key_copy);

            const group = try convertGroupAlloc(allocator, entry.value_ptr.*);
            errdefer {
                var owned = group;
                owned.deinit(allocator);
            }

            const gop = try config.groups.getOrPut(allocator, key_copy);
            if (gop.found_existing) return error.DuplicateGroup;
            gop.value_ptr.* = group;
        }
    }

    if (raw.bindings) |bindings| {
        var iter = bindings.map.iterator();
        while (iter.next()) |entry| {
            const key_copy = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(key_copy);

            const binding = try convertBindingAlloc(allocator, entry.value_ptr.*);
            errdefer {
                var owned = binding;
                owned.deinit(allocator);
            }

            const gop = try config.bindings.getOrPut(allocator, key_copy);
            if (gop.found_existing) return error.DuplicateBinding;
            gop.value_ptr.* = binding;
        }
    }

    return config;
}

fn convertInjectSetAlloc(
    allocator: std.mem.Allocator,
    raw: RawInjectSet,
) !model.InjectSet {
    return .{
        .groups = try dupStringSliceAlloc(allocator, raw.groups orelse &.{}),
        .global = try dupStringSliceAlloc(allocator, raw.global orelse &.{}),
        .project = try dupStringSliceAlloc(allocator, raw.project orelse &.{}),
    };
}

fn convertCommandRulesAlloc(
    allocator: std.mem.Allocator,
    raw_rules: []const RawCommandRule,
) ![]model.CommandRule {
    var rules: std.ArrayList(model.CommandRule) = .empty;
    errdefer {
        for (rules.items) |*rule| rule.deinit(allocator);
        rules.deinit(allocator);
    }

    for (raw_rules) |raw_rule| {
        try rules.append(allocator, .{
            .match = .{
                .argv = if (raw_rule.match.argv) |argv|
                    try dupStringSliceAlloc(allocator, argv)
                else
                    null,
                .argv_prefix = if (raw_rule.match.argv_prefix) |argv_prefix|
                    try dupStringSliceAlloc(allocator, argv_prefix)
                else
                    null,
            },
            .inject = try convertInjectSetAlloc(allocator, raw_rule.inject),
        });
    }

    return rules.toOwnedSlice(allocator);
}

fn convertBindingAlloc(allocator: std.mem.Allocator, raw: RawBinding) !model.Binding {
    if (raw.account != null and raw.env != null) return error.InvalidBinding;
    if (raw.account) |account| {
        return .{
            .source = .{ .account = try allocator.dupe(u8, account) },
        };
    }
    if (raw.env) |env_name| {
        return .{
            .source = .{ .env = try allocator.dupe(u8, env_name) },
        };
    }
    return error.InvalidBinding;
}

fn convertGroupAlloc(allocator: std.mem.Allocator, raw: RawGroup) !model.Group {
    return .{
        .global = try dupStringSliceAlloc(allocator, raw.global orelse &.{}),
        .project = try dupStringSliceAlloc(allocator, raw.project orelse &.{}),
    };
}

fn dupStringSliceAlloc(allocator: std.mem.Allocator, values: []const []const u8) ![][]const u8 {
    var duped = try allocator.alloc([]const u8, values.len);
    var initialized: usize = 0;
    errdefer {
        for (duped[0..initialized]) |item| allocator.free(item);
        allocator.free(duped);
    }

    for (values, 0..) |value, index| {
        duped[index] = try allocator.dupe(u8, value);
        initialized = index + 1;
    }

    return duped;
}
