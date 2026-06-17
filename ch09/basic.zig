const std = @import("std");
const Io = std.Io;

fn longComputation(io: Io, input: u64) !u64 {
    // Simulate some work (in a real program this could be CPU work or I/O)
    try io.sleep(Io.Duration.fromSeconds(1), .awake);
    return input * input;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    // Launch two independent computations concurrently
    var task1 = io.async(longComputation, .{ io, 42 });
    defer _ = task1.cancel(io) catch {};
    var task2 = io.async(longComputation, .{ io, 7 });
    defer _ = task2.cancel(io) catch {};

    // Do unrelated work while both tasks run in the background
    var buf: [128]u8 = undefined;
    const working = std.fmt.bufPrint(
        &buf,
        "Tasks launched; doing other work...\n",
        .{},
    ) catch unreachable;
    try std.Io.File.stdout().writeStreamingAll(io, working);

    // Simulate additional CPU work the main thread can do concurrently
    var sum: u64 = 0;
    for (0..1_000_000) |i| sum +%= i;

    // Now collect both results
    const result1 = try task1.await(io);
    const result2 = try task2.await(io);

    const s = std.fmt.bufPrint(
        &buf,
        "42^2={d}, 7^2={d}, side-sum={d}\n",
        .{ result1, result2, sum },
    ) catch unreachable;
    try std.Io.File.stdout().writeStreamingAll(io, s);
}
