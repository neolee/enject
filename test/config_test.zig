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

test "config parser preserves groups references in inject sets" {
    const allocator = std.testing.allocator;
    var config = try parser.parseSliceAlloc(allocator,
        \\version = 1
        \\
        \\[groups.common_llm]
        \\global = ["OPENAI_API_KEY", "ANTHROPIC_AUTH_TOKEN"]
        \\
        \\[[rules.command]]
        \\match.argv_prefix = ["opencode"]
        \\inject.groups = ["common_llm"]
        \\inject.global = ["JINA_API_KEY"]
        \\
    );
    defer config.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), config.command_rules.len);
    try std.testing.expectEqual(@as(usize, 1), config.command_rules[0].inject.groups.len);
    try std.testing.expectEqualStrings("common_llm", config.command_rules[0].inject.groups[0]);
    try std.testing.expectEqual(@as(usize, 1), config.command_rules[0].inject.global.len);
    try std.testing.expectEqualStrings("JINA_API_KEY", config.command_rules[0].inject.global[0]);
}

test "config parser loads env binding sources" {
    const allocator = std.testing.allocator;
    var config = try parser.parseSliceAlloc(allocator,
        \\version = 1
        \\
        \\[bindings]
        \\MY_TOOL_API_KEY = { env = "OPENAI_API_KEY" }
        \\
    );
    defer config.deinit(allocator);

    const binding = config.getBinding("MY_TOOL_API_KEY").?;
    switch (binding.source) {
        .env => |env_name| try std.testing.expectEqualStrings("OPENAI_API_KEY", env_name),
        .account => return error.ExpectedEnvBinding,
    }
}
