const std = @import("std");

pub const Binding = struct {
    source: Source,

    pub const Source = union(enum) {
        account: []const u8,
        env: []const u8,
    };

    pub fn deinit(self: *Binding, allocator: std.mem.Allocator) void {
        switch (self.source) {
            .account => |account| allocator.free(account),
            .env => |env_name| allocator.free(env_name),
        }
        self.* = undefined;
    }
};

pub const Group = struct {
    global: [][]const u8,
    project: [][]const u8,

    pub fn deinit(self: *Group, allocator: std.mem.Allocator) void {
        freeStringSlice(allocator, self.global);
        freeStringSlice(allocator, self.project);
        self.* = undefined;
    }
};

pub const InjectSet = struct {
    groups: [][]const u8,
    global: [][]const u8,
    project: [][]const u8,

    pub fn empty() InjectSet {
        return .{
            .groups = &.{},
            .global = &.{},
            .project = &.{},
        };
    }

    pub fn deinit(self: *InjectSet, allocator: std.mem.Allocator) void {
        freeStringSlice(allocator, self.groups);
        freeStringSlice(allocator, self.global);
        freeStringSlice(allocator, self.project);
        self.* = empty();
    }
};

pub const CommandMatch = struct {
    argv: ?[][]const u8 = null,
    argv_prefix: ?[][]const u8 = null,

    pub fn deinit(self: *CommandMatch, allocator: std.mem.Allocator) void {
        if (self.argv) |argv| freeStringSlice(allocator, argv);
        if (self.argv_prefix) |argv_prefix| freeStringSlice(allocator, argv_prefix);
        self.* = .{};
    }
};

pub const CommandRule = struct {
    match: CommandMatch = .{},
    inject: InjectSet = .empty(),

    pub fn deinit(self: *CommandRule, allocator: std.mem.Allocator) void {
        self.match.deinit(allocator);
        self.inject.deinit(allocator);
    }
};

pub const Config = struct {
    version: u32 = 1,
    project_name: ?[]const u8 = null,
    directory_rule: ?InjectSet = null,
    command_rules: []CommandRule = &.{},
    groups: std.StringHashMapUnmanaged(Group) = .{},
    bindings: std.StringHashMapUnmanaged(Binding) = .{},

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        if (self.project_name) |name| allocator.free(name);
        if (self.directory_rule) |*directory_rule| directory_rule.deinit(allocator);
        for (self.command_rules) |*rule| rule.deinit(allocator);
        allocator.free(self.command_rules);

        var group_iter = self.groups.iterator();
        while (group_iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        self.groups.deinit(allocator);

        var iter = self.bindings.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        self.bindings.deinit(allocator);
        self.* = .{};
    }

    pub fn getBinding(self: *const Config, env_name: []const u8) ?Binding {
        return self.bindings.get(env_name);
    }

    pub fn getGroup(self: *const Config, name: []const u8) ?Group {
        return self.groups.get(name);
    }
};

fn freeStringSlice(allocator: std.mem.Allocator, values: [][]const u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}
