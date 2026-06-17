const std = @import("std");

const KiB = 1024;
const MiB = 1024 * 1024;

// Generic benchmark for allocators that support individual .free()
fn benchmarkStandard(
    io: std.Io,
    allocator: std.mem.Allocator,
    name: []const u8,
    count: usize,
    repeat: usize,
) !void {
    var total_alloc_ns: u64 = 0;

    for (0..repeat) |_| {
        const t_start = std.Io.Timestamp.now(io, .awake);
        const arr = try allocator.alloc(i32, count);
        const elapsed: u64 = @intCast(t_start.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds);

        total_alloc_ns += elapsed;

        // Housekeeping: return memory so we don't OOM (not measured in time)
        allocator.free(arr);
    }

    printStats(name, count, repeat, total_alloc_ns);
}

// Specialized benchmark for Arena to use .reset()
fn benchmarkArena(
    io: std.Io,
    parent_allocator: std.mem.Allocator,
    name: []const u8,
    count: usize,
    repeat: usize,
) !void {
    var total_alloc_ns: u64 = 0;

    // We init the Arena ONCE outside the loop
    var arena = std.heap.ArenaAllocator.init(parent_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    for (0..repeat) |_| {
        const t_start = std.Io.Timestamp.now(io, .awake);

        // Allocation is just bumping a pointer
        _ = try allocator.alloc(i32, count);

        const elapsed: u64 = @intCast(t_start.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds);
        total_alloc_ns += elapsed;

        // Housekeeping: Reset the arena cursor.
        _ = arena.reset(.retain_capacity);
    }

    printStats(name, count, repeat, total_alloc_ns);
}

fn printStats(
    name: []const u8,
    count: usize,
    repeat: usize,
    total_ns: u64,
) void {
    const totalBytes = count * @sizeOf(i32);
    const totalMib = @as(f64, @floatFromInt(totalBytes)) / @as(f64, MiB);
    const mean_alloc_us = (total_ns / repeat) / 1_000;

    std.debug.print(
        "{s:24}: {d:6.2} MiB x {d:2} -> alloc: {d:5} µs\n",
        .{ name, totalMib, repeat, mean_alloc_us },
    );
}

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    const default_count: usize = 10_000_000;
    const default_repeat: usize = 10;

    var count: usize = default_count;
    var repeat: usize = default_repeat;

    if (args.len >= 2) count = try std.fmt.parseInt(usize, args[1], 10);
    if (args.len >= 3) repeat = try std.fmt.parseInt(usize, args[2], 10);

    std.debug.print(
        "  - Benchmarking allocators: {d} i32s x {d} runs -  \n",
        .{ count, repeat },
    );

    // 1. Debug Allocator (formerly GeneralPurposeAllocator)
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    try benchmarkStandard(
        init.io,
        gpa_state.allocator(),
        "DebugAllocator",
        count,
        repeat,
    );

    // 2. Page Allocator
    try benchmarkStandard(
        init.io,
        std.heap.page_allocator,
        "PageAllocator",
        count,
        repeat,
    );

    // 3. Fixed Buffer Allocator (Stack based for speed)
    const fba_size = 64 * MiB;
    const backing_buffer = try std.heap.page_allocator.alloc(u8, fba_size);
    defer std.heap.page_allocator.free(backing_buffer);

    var fba = std.heap.FixedBufferAllocator.init(backing_buffer);
    try benchmarkStandard(
        init.io,
        fba.allocator(),
        "FixedBufferAllocator",
        count,
        repeat,
    );

    // 4. Arena Allocator (uses specialized function)
    try benchmarkArena(
        init.io,
        allocator,
        "ArenaAllocator",
        count,
        repeat,
    );
}
