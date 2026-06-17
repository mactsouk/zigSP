const std = @import("std");

var counter: u32 = 0;

fn incrementCounter() void {
    counter += 1;
}

pub fn main(init: std.process.Init) !void {
    _ = init;
    var threads: [200]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, incrementCounter, .{});
    }

    for (threads) |t| {
        t.join();
    }
    std.debug.print("Counter: {} (Expected: 200)\n", .{counter});
}
