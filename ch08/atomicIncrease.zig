const std = @import("std");
const Thread = std.Thread;

pub fn main(init: std.process.Init) !void {
    _ = init;
    var counter: usize = 0;
    const thread_count = 4;
    const increments = 100_000;

    const threads = try std.heap.page_allocator.alloc(
        Thread,
        thread_count,
    );
    defer std.heap.page_allocator.free(threads);

    for (threads) |*t| {
        t.* = try Thread.spawn(
            .{},
            threadMain,
            .{ &counter, increments },
        );
    }

    for (threads) |t| {
        t.join();
    }

    // Atomically load the final value
    const final = @atomicLoad(usize, &counter, .seq_cst);
    std.debug.print("Final counter value: {d}\n", .{final});
}

fn threadMain(counter_ptr: *usize, increments: usize) void {
    var i: usize = 0;
    while (i < increments) : (i += 1) {
        _ = @atomicRmw(usize, counter_ptr, .Add, 1, .seq_cst);
    }
}
