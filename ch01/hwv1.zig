const std = @import("std");

pub fn main(_: std.process.Init.Minimal) !void {
    std.debug.print("Hello {s}!\n", .{"World"});
}
