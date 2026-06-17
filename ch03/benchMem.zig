const std = @import("std");

const Person = struct {
    name: []const u8,
    age: u8,
};

const ITERATIONS = 100_000;

pub fn main(init: std.process.Init) !void {
    // 1. Benchmark Page Allocator
    // This allocator asks the OS for memory pages directly (syscalls).
    const page_alloc = std.heap.page_allocator;

    var start = std.Io.Timestamp.now(init.io, .awake);

    for (0..ITERATIONS) |_| {
        const ptr = try page_alloc.create(Person);
        ptr.* = .{ .name = "Bench", .age = 99 };
        std.mem.doNotOptimizeAway(ptr.age);
        page_alloc.destroy(ptr);
    }

    const page_time: u64 = @intCast(start.durationTo(std.Io.Timestamp.now(init.io, .awake)).nanoseconds);

    // 2. Benchmark Debug Allocator (formerly GeneralPurposeAllocator)
    // This allocator manages memory in user-space, batching OS requests.
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    start = std.Io.Timestamp.now(init.io, .awake);

    for (0..ITERATIONS) |_| {
        const ptr = try gpa.create(Person);
        ptr.* = .{ .name = "Bench", .age = 99 };
        std.mem.doNotOptimizeAway(ptr.age);
        gpa.destroy(ptr);
    }

    const gpa_time: u64 = @intCast(start.durationTo(std.Io.Timestamp.now(init.io, .awake)).nanoseconds);

    std.debug.print("Iterations: {d}\n", .{ITERATIONS});
    std.debug.print("Page Allocator: {d} ms\n", .{page_time / std.time.ns_per_ms});
    std.debug.print("Debug Alloc   : {d} ms\n", .{gpa_time / std.time.ns_per_ms});

    const speedup = @as(f64, @floatFromInt(page_time)) / @as(f64, @floatFromInt(gpa_time));
    std.debug.print("DebugAllocator is {d:.2}x faster for small allocations.\n", .{speedup});
}
