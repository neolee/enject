const std = @import("std");

pub const Binding = struct {
    account: []const u8,
};

pub const InjectSet = struct {
    global: [][]const u8,
    project: [][]const u8,

    pub fn empty() InjectSet {
        return .{
            .global = &.{},
            .project = &.{},
        };
    }

    pub fn deinit(self: *InjectSet, allocator: std.mem.Allocator) void {
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
    bindings: std.StringHashMapUnmanaged(Binding) = .{},

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        if (self.project_name) |name| allocator.free(name);
        if (self.directory_rule) |*directory_rule| directory_rule.deinit(allocator);
        for (self.command_rules) |*rule| rule.deinit(allocator);
        allocator.free(self.command_rules);

        var iter = self.bindings.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.account);
        }
        self.bindings.deinit(allocator);
        self.* = .{};
    }

    pub fn getBinding(self: *const Config, env_name: []const u8) ?Binding {
        return self.bindings.get(env_name);
    }
};

fn freeStringSlice(allocator: std.mem.Allocator, values: [][]const u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}
