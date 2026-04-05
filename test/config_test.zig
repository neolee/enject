const std = @import("std");
const enject = @import("enject");

const parser = enject.config.parser;

test "config parser loads minimal config defaults" {
    const allocator = std.testing.allocator;
    var config = try parser.parseSliceAlloc(allocator,
        \\version = 1
        \\
    );
    defer config.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), config.version);
    try std.testing.expect(config.project_name == null);
    try std.testing.expect(config.directory_rule == null);
    try std.testing.expectEqual(@as(usize, 0), config.command_rules.len);
    try std.testing.expectEqual(@as(usize, 0), config.bindings.count());
}

test "config parser rejects invalid TOML" {
    const allocator = std.testing.allocator;
    _ = parser.parseSliceAlloc(allocator,
        \\version = 1
        \\[project
        \\name = "acme"
        \\
    ) catch return;

    return error.ExpectedParseFailure;
}

test "config parser rejects invalid binding schema" {
    const allocator = std.testing.allocator;
    _ = parser.parseSliceAlloc(allocator,
        \\version = 1
        \\
        \\[bindings]
        \\OPENAI_API_KEY = { wrong = "openai_api_key" }
        \\
    ) catch return;

    return error.ExpectedParseFailure;
}
