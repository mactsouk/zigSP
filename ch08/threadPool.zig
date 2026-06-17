const std = @import("std");

// Io.Group is an abstraction over async execution. Behavior depends
// on the Io vtable in use. Under the default Threaded Io, it dispatches
// to a worker thread pool; effectively the same model std.Thread.Pool
// provides. Under an evented Io (io_uring-based), CPU-bound functions
// that never suspend would block the event loop.
pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var group: std.Io.Group = .init;
    defer group.cancel(io);

    group.async(io, work, .{@as(u32, 3)});
    group.async(io, work, .{@as(u32, 5)});
    group.async(io, work, .{@as(u32, 7)});

    try group.await(io);
}

fn work(inc: u32) void {
    std.debug.print("Start Inc = {d}\n", .{inc});
    var total: u32 = 0;
    var i: u32 = 0;
    while (i < 100000) : (i += 1) {
        total += inc;
    }
    std.debug.print("Total = {d}, Inc = {d}\n", .{ total, inc });
}
