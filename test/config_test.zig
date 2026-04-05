const std = @import("std");
const enject = @import("enject");

const config = enject.config;
const parser = enject.config.parser;

test "config parser loads minimal config defaults" {
    const allocator = std.testing.allocator;
    var parsed = try parser.parseSliceAlloc(allocator,
        \\version = 1
        \\
    );
    defer parsed.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), parsed.version);
    try std.testing.expect(parsed.project_name == null);
    try std.testing.expect(parsed.directory_rule == null);
    try std.testing.expectEqual(@as(usize, 0), parsed.command_rules.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.bindings.count());
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
    var parsed = try parser.parseSliceAlloc(allocator,
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
    defer parsed.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), parsed.command_rules.len);
    try std.testing.expectEqual(@as(usize, 1), parsed.command_rules[0].inject.groups.len);
    try std.testing.expectEqualStrings("common_llm", parsed.command_rules[0].inject.groups[0]);
    try std.testing.expectEqual(@as(usize, 1), parsed.command_rules[0].inject.global.len);
    try std.testing.expectEqualStrings("JINA_API_KEY", parsed.command_rules[0].inject.global[0]);
}

test "config parser loads env binding sources" {
    const allocator = std.testing.allocator;
    var parsed = try parser.parseSliceAlloc(allocator,
        \\version = 1
        \\
        \\[bindings]
        \\MY_TOOL_API_KEY = { env = "OPENAI_API_KEY" }
        \\
    );
    defer parsed.deinit(allocator);

    const binding = parsed.getBinding("MY_TOOL_API_KEY").?;
    switch (binding.source) {
        .env => |env_name| try std.testing.expectEqualStrings("OPENAI_API_KEY", env_name),
        .account => return error.ExpectedEnvBinding,
    }
}

test "config validation rejects rules.directory in global config" {
    const allocator = std.testing.allocator;
    var parsed = try parser.parseSliceAlloc(allocator,
        \\version = 1
        \\
        \\[rules.directory]
        \\global = ["OPENAI_API_KEY"]
        \\
    );
    defer parsed.deinit(allocator);

    try std.testing.expectError(
        error.DirectoryRulesOnlyAllowedInProjectConfig,
        config.validateForSource(&parsed, .global),
    );
}

test "config validation allows rules.directory in project config" {
    const allocator = std.testing.allocator;
    var parsed = try parser.parseSliceAlloc(allocator,
        \\version = 1
        \\
        \\[project]
        \\name = "acme"
        \\
        \\[rules.directory]
        \\global = ["OPENAI_API_KEY"]
        \\
    );
    defer parsed.deinit(allocator);

    try config.validateForSource(&parsed, .project);
}
