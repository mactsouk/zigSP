const std = @import("std");

// Zig 0.16: const c = @cImport(@cInclude("unistd.h"));
// Zig 0.17: zig translate-c -lc isExecutableC_c.h > isExecutableC_c.zig
const c = @import("isExecutableC_c.zig");

// Import the `access()` function from C
extern fn access(path: [*:0]const u8, mode: c_int) c_int;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 2) {
        std.debug.print("Usage: isExecutableC <file>\n", .{});
        return;
    }

    const filePath = args[1];
    if (access(filePath, c.X_OK) == 0) {
        std.debug.print("{s} is executable\n", .{filePath});
    } else {
        std.debug.print("{s} is NOT executable or does not exist\n", .{filePath});
    }
}
