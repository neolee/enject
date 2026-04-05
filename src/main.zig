const std = @import("std");
pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    _ = args;
    std.debug.print(
        \\enject is under active development.
        \\
        \\The current repository contains provider implementations and tests,
        \\but the user-facing command set has not been implemented yet.
        \\
    , .{});
}
