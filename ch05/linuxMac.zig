const std = @import("std");
const builtin = @import("builtin");

pub fn main(_: std.process.Init.Minimal) !void {
    if (builtin.os.tag == .linux) {
        std.debug.print("This is a Linux machine!\n", .{});
    } else if (builtin.os.tag == .macos or builtin.os.tag.isBSD()) {
        std.debug.print("This is a macOS machine!\n", .{});
    } else {
        @compileError("Unsupported operating system");
    }
}
