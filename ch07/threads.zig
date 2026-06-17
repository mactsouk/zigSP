const std = @import("std");

fn threadFunc(arg: usize) void {
    std.debug.print("Hello from thread! Arg = {}\n", .{arg});
}

pub fn main(init: std.process.Init) !void {
    _ = init;
    const thr1 = try std.Thread.spawn(.{}, threadFunc, .{1234});
    std.debug.print("Hello from main thread!\n", .{});
    const thr2 = try std.Thread.spawn(.{}, threadFunc, .{4321});

    thr1.join();
    thr2.join();

    std.debug.print("All threads have finished.\n", .{});
}
