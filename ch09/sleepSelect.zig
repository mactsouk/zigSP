const std = @import("std");
const Io = std.Io;

fn sleepFor(io: Io, seconds: i64) void {
    io.sleep(Io.Duration.fromSeconds(seconds), .awake) catch {};
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    const Result = union(enum) { t1: void, t2: void };

    var buf: [2]Result = undefined;
    var sel = Io.Select(Result).init(io, &buf);
    defer sel.cancelDiscard();

    sel.async(.t1, sleepFor, .{ io, @as(i64, 1) });
    sel.async(.t2, sleepFor, .{ io, @as(i64, 2) });

    // Wait for the first one to complete
    const winner = try sel.await();

    switch (winner) {
        .t1 => try std.Io.File.stdout().writeStreamingAll(
            io,
            "Task 1 finished first\n",
        ),
        .t2 => try std.Io.File.stdout().writeStreamingAll(
            io,
            "Task 2 finished first\n",
        ),
    }
}
