const std = @import("std");

pub fn main(_: std.process.Init.Minimal) void {
    var x: i32 = 42;
    const ptr: *i32 = &x;
    std.debug.print("Memory address of x: {}\n", .{ptr});

    // Print the original value of x via the pointer
    std.debug.print("Value of x via pointer: {}\n", .{ptr.*});

    ptr.* = 100;
    std.debug.print("Modified value of x via pointer: {}\n", .{x});
}
