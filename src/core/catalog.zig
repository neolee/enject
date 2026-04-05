const std = @import("std");
const parser = @import("../config/parser.zig");
const model = @import("../config/model.zig");

const builtins_toml = @embedFile("catalog.toml");

pub fn loadAlloc(allocator: std.mem.Allocator) !model.Config {
    return parser.parseSliceAlloc(allocator, builtins_toml);
}

pub fn text() []const u8 {
    return builtins_toml;
}
