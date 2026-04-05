const std = @import("std");

pub const Record = struct {
    path: []const u8,
    digest_hex: []const u8,
};

pub const ProjectConfigLocation = struct {
    root_dir: []const u8,
    config_path: []const u8,

    pub fn deinit(self: *ProjectConfigLocation, allocator: std.mem.Allocator) void {
        allocator.free(self.root_dir);
        allocator.free(self.config_path);
        self.* = undefined;
    }
};

pub const Discovery = struct {
    trusted: ?ProjectConfigLocation = null,
    untrusted: ?ProjectConfigLocation = null,

    pub fn deinit(self: *Discovery, allocator: std.mem.Allocator) void {
        if (self.trusted) |*trusted| trusted.deinit(allocator);
        if (self.untrusted) |*untrusted| untrusted.deinit(allocator);
        self.* = .{};
    }
};

pub const Store = struct {
    path: []const u8,
    io: std.Io,

    pub fn init(path: []const u8, io: std.Io) Store {
        return .{
            .path = path,
            .io = io,
        };
    }

    pub fn trustConfig(self: Store, allocator: std.mem.Allocator, config_path: []const u8) !void {
        const absolute_config_path = try absolutePathAlloc(allocator, self.io, config_path);
        defer allocator.free(absolute_config_path);

        const config_data = try std.Io.Dir.cwd().readFileAlloc(self.io, absolute_config_path, allocator, .unlimited);
        defer allocator.free(config_data);

        const digest_hex = try digestHexAlloc(allocator, config_data);
        defer allocator.free(digest_hex);

        var records = try loadRecordsAlloc(allocator, self.io, self.path);
        defer freeRecords(allocator, records);

        var updated = false;
        for (records) |*record| {
            if (std.mem.eql(u8, record.path, absolute_config_path)) {
                allocator.free(record.digest_hex);
                record.digest_hex = try allocator.dupe(u8, digest_hex);
                updated = true;
                break;
            }
        }

        if (!updated) {
            const old_records = records;
            var list: std.ArrayList(Record) = .empty;
            defer list.deinit(allocator);
            try list.appendSlice(allocator, old_records);
            try list.append(allocator, .{
                .path = try allocator.dupe(u8, absolute_config_path),
                .digest_hex = try allocator.dupe(u8, digest_hex),
            });
            allocator.free(old_records);
            records = try list.toOwnedSlice(allocator);
        }

        try writeRecords(self, allocator, records);
    }

    pub fn isTrusted(self: Store, allocator: std.mem.Allocator, config_path: []const u8) !bool {
        const absolute_config_path = try absolutePathAlloc(allocator, self.io, config_path);
        defer allocator.free(absolute_config_path);

        const config_data = try std.Io.Dir.cwd().readFileAlloc(self.io, absolute_config_path, allocator, .unlimited);
        defer allocator.free(config_data);

        const digest_hex = try digestHexAlloc(allocator, config_data);
        defer allocator.free(digest_hex);

        const records = try loadRecordsAlloc(allocator, self.io, self.path);
        defer freeRecords(allocator, records);

        for (records) |record| {
            if (std.mem.eql(u8, record.path, absolute_config_path)) {
                return std.mem.eql(u8, record.digest_hex, digest_hex);
            }
        }

        return false;
    }

    pub fn discoverProjectConfigAlloc(
        self: Store,
        allocator: std.mem.Allocator,
        cwd_path: []const u8,
    ) !Discovery {
        var current_dir = try absolutePathAlloc(allocator, self.io, cwd_path);
        defer allocator.free(current_dir);

        while (true) {
            const candidate = try std.fs.path.join(allocator, &.{ current_dir, ".enject" });
            defer allocator.free(candidate);

            if (try fileExists(self.io, candidate)) {
                const location = ProjectConfigLocation{
                    .root_dir = try allocator.dupe(u8, current_dir),
                    .config_path = try allocator.dupe(u8, candidate),
                };
                if (try self.isTrusted(allocator, candidate)) {
                    return .{ .trusted = location };
                }
                return .{ .untrusted = location };
            }

            const parent = std.fs.path.dirname(current_dir) orelse break;
            if (std.mem.eql(u8, parent, current_dir)) break;

            const next_dir = try allocator.dupe(u8, parent);
            allocator.free(current_dir);
            current_dir = next_dir;
        }

        return .{};
    }
};

fn loadRecordsAlloc(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]Record {
    const file_data = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return allocator.alloc(Record, 0),
        else => return err,
    };
    defer allocator.free(file_data);

    var records: std.ArrayList(Record) = .empty;
    errdefer {
        freeRecords(allocator, records.items);
        records.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, file_data, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        const tab_index = std.mem.indexOfScalar(u8, line, '\t') orelse return error.InvalidTrustStore;
        try records.append(allocator, .{
            .digest_hex = try allocator.dupe(u8, line[0..tab_index]),
            .path = try allocator.dupe(u8, line[tab_index + 1 ..]),
        });
    }

    return records.toOwnedSlice(allocator);
}

fn writeRecords(self: Store, allocator: std.mem.Allocator, records: []const Record) !void {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    for (records) |record| {
        try output.appendSlice(allocator, record.digest_hex);
        try output.append(allocator, '\t');
        try output.appendSlice(allocator, record.path);
        try output.append(allocator, '\n');
    }

    try std.Io.Dir.cwd().writeFile(self.io, .{
        .sub_path = self.path,
        .data = output.items,
    });
}

fn freeRecords(allocator: std.mem.Allocator, records: []Record) void {
    for (records) |record| {
        allocator.free(record.path);
        allocator.free(record.digest_hex);
    }
    allocator.free(records);
}

fn fileExists(io: std.Io, path: []const u8) !bool {
    var file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return false,
        else => return err,
    };
    file.close(io);
    return true;
}

fn absolutePathAlloc(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return std.fs.path.resolve(allocator, &.{path});

    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.resolve(allocator, &.{ cwd, path });
}

fn digestHexAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});

    var hex: [digest.len * 2]u8 = undefined;
    hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &hex);
}
