const std = @import("std");
const Val = std.atomic.Value(u32);
const Order = std.builtin.AtomicOrder;

fn toRunInThread(v: *Val) void {
    _ = v.fetchAdd(1, Order.monotonic);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var value = Val.init(42);

    const thread = try std.Thread.spawn(.{
        .allocator = allocator,
        .stack_size = 1024,
    }, toRunInThread, .{&value});

    thread.join();

    std.debug.print(
        "Expected value 43: {}\n",
        .{value.load(Order.acquire)},
    );
}
