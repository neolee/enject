const std = @import("std");
const config = @import("../config/root.zig");

const builtins_toml = @embedFile("catalog.toml");

pub fn loadAlloc(allocator: std.mem.Allocator) !config.model.Config {
    var parsed = try config.parser.parseSliceAlloc(allocator, builtins_toml);
    errdefer parsed.deinit(allocator);

    try config.validateForSource(&parsed, .built_in);
    return parsed;
}

pub fn text() []const u8 {
    return builtins_toml;
}
