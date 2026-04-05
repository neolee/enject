const std = @import("std");

pub fn writeGenericPassword(
    allocator: std.mem.Allocator,
    io: std.Io,
    service: []const u8,
    account: []const u8,
    value: []const u8,
) !void {
    const result = try runSecurity(allocator, io, &.{
        "security",
        "add-generic-password",
        "-U",
        "-s",
        service,
        "-a",
        account,
        "-w",
        value,
    });
    defer freeRunResult(allocator, result);
    try expectSuccess(result);
}

pub fn readGenericPasswordAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    service: []const u8,
    account: []const u8,
) ![]u8 {
    const result = try runSecurity(allocator, io, &.{
        "security",
        "find-generic-password",
        "-w",
        "-s",
        service,
        "-a",
        account,
    });
    defer freeRunResult(allocator, result);

    if (!isSuccess(result)) {
        if (containsNotFound(result.stderr)) return error.NotFound;
        return error.SecurityCommandFailed;
    }

    return allocator.dupe(u8, std.mem.trimEnd(u8, result.stdout, "\r\n"));
}

pub fn deleteGenericPassword(
    allocator: std.mem.Allocator,
    io: std.Io,
    service: []const u8,
    account: []const u8,
) !void {
    const result = try runSecurity(allocator, io, &.{
        "security",
        "delete-generic-password",
        "-s",
        service,
        "-a",
        account,
    });
    defer freeRunResult(allocator, result);

    if (!isSuccess(result)) {
        if (containsNotFound(result.stderr)) return error.NotFound;
        return error.SecurityCommandFailed;
    }
}

fn runSecurity(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
) !std.process.RunResult {
    return std.process.run(allocator, io, .{ .argv = argv });
}

fn freeRunResult(allocator: std.mem.Allocator, result: std.process.RunResult) void {
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

fn expectSuccess(result: std.process.RunResult) !void {
    if (!isSuccess(result)) return error.SecurityCommandFailed;
}

fn isSuccess(result: std.process.RunResult) bool {
    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn containsNotFound(stderr: []const u8) bool {
    return std.mem.indexOf(u8, stderr, "could not be found") != null;
}
