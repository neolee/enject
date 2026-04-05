pub const model = @import("model.zig");
pub const parser = @import("parser.zig");

pub const SourceKind = enum {
    built_in,
    global,
    project,
};

pub fn validateForSource(config: *const model.Config, source: SourceKind) !void {
    if (source != .project and config.directory_rule != null) {
        return error.DirectoryRulesOnlyAllowedInProjectConfig;
    }
}
