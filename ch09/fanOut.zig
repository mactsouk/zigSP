const std = @import("std");
const Io = std.Io;

fn fetchData(io: Io, id: u32, out: *u64) !void {
    // Simulate network/file I/O
    try io.sleep(
        Io.Duration.fromMilliseconds(300 + @as(i64, id) * 100),
        .awake,
    );
    out.* = 1000 * id;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var results: [3]u64 = undefined;

    // Start three tasks concurrently
    var t1 = try io.concurrent(
        fetchData,
        .{ io, @as(u32, 1), &results[0] },
    );
    defer _ = t1.cancel(io) catch {};

    var t2 = try io.concurrent(
        fetchData,
        .{ io, @as(u32, 2), &results[1] },
    );
    defer _ = t2.cancel(io) catch {};

    var t3 = try io.concurrent(
        fetchData,
        .{ io, @as(u32, 3), &results[2] },
    );
    defer _ = t3.cancel(io) catch {};

    // Wait for all tasks
    try t1.await(io);
    try t2.await(io);
    try t3.await(io);

    var buf: [128]u8 = undefined;
    const s = std.fmt.bufPrint(
        &buf,
        "Results: {d} {d} {d}\n",
        .{ results[0], results[1], results[2] },
    ) catch unreachable;
    try std.Io.File.stdout().writeStreamingAll(io, s);
}
