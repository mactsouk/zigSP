const std = @import("std");
const print = std.debug.print;

/// File writing benchmark with configurable parameters
pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 4) {
        print(
            "Usage: {s} <file_size_mb> <trials> [buffer_size1 ...]\n",
            .{args[0]},
        );
        print("Example: {s} 100 5 128 1024 4096 16384\n", .{args[0]});
        return;
    }

    const file_size_mb = try std.fmt.parseUnsigned(usize, args[1], 10);
    const trials = try std.fmt.parseUnsigned(usize, args[2], 10);
    const buffer_sizes = args[3..];

    // Pre-generate test data
    print("Generating {d}MB of random test data...\n", .{file_size_mb});
    const data = try generateTestData(init.io, allocator, file_size_mb);
    defer allocator.free(data);

    // Print benchmark header
    print(
        "\nFile Writing Benchmark - {d} MB File - {d} Trials\n",
        .{ file_size_mb, trials },
    );
    print("========================================================================\n", .{});
    print(
        "{s:<15} {s:<15} {s:<20} {s:<15}\n",
        .{ "Buffer Size", "Avg Time (ms)", "Avg Throughput", "Std Dev" },
    );
    print("------------------------------------------------------------------------\n", .{});

    for (buffer_sizes) |size_str| {
        const buffer_size = std.fmt.parseInt(usize, size_str, 10) catch |err| {
            print("Skipping invalid buffer size '{s}': {}\n", .{ size_str, err });
            continue;
        };

        try benchmarkBufferSize(init.io, allocator, data, buffer_size, trials);
    }
}

/// Calculate standard deviation of benchmark results
fn calculateStdDev(values: []f64, mean: f64) f64 {
    var sum: f64 = 0;
    for (values) |value| {
        const diff = value - mean;
        sum += diff * diff;
    }
    const variance = sum / @as(f64, @floatFromInt(values.len));
    return std.math.sqrt(variance);
}

/// Generate test data with random printable characters
fn generateTestData(
    io: std.Io,
    allocator: std.mem.Allocator,
    size_mb: usize,
) ![]u8 {
    const size_bytes = size_mb * 1024 * 1024;
    const buffer = try allocator.alloc(u8, size_bytes);

    var seed_bytes: [8]u8 = undefined;
    io.random(&seed_bytes);
    var prng = std.Random.DefaultPrng.init(@bitCast(seed_bytes));
    const rand = prng.random();

    // Fill buffer with printable ASCII (32-126)
    for (buffer) |*byte| {
        byte.* = rand.intRangeAtMost(u8, 32, 126);
    }

    return buffer;
}

/// Benchmark a specific buffer size across multiple trials
fn benchmarkBufferSize(
    io: std.Io,
    allocator: std.mem.Allocator,
    data: []const u8,
    buffer_size: usize,
    trials: usize,
) !void {
    const file_size = data.len;
    const file_size_mb = @as(f64, @floatFromInt(file_size)) / (1024.0 * 1024.0);

    var durations = try std.ArrayListUnmanaged(f64).initCapacity(allocator, trials);
    defer durations.deinit(allocator);

    var total_time: f64 = 0;

    for (0..trials) |trial| {
        const temp_path = try std.fmt.allocPrint(
            allocator,
            "/tmp/bench_write_{d}_{d}.tmp",
            .{ buffer_size, trial },
        );
        defer allocator.free(temp_path);
        defer cleanupTestFile(io, temp_path);

        const file = try std.Io.Dir.cwd().createFile(io, temp_path, .{});
        defer file.close(io);

        const t_start = std.Io.Timestamp.now(io, .awake);
        var written: usize = 0;

        while (written < file_size) {
            const to_write = @min(buffer_size, file_size - written);
            try file.writeStreamingAll(io, data[written..][0..to_write]);
            written += to_write;
        }

        const elapsed_ns: u64 = @intCast(t_start.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds);
        const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;

        try durations.append(allocator, elapsed_ms);
        total_time += elapsed_ms;
    }

    const avg_time = total_time / @as(f64, @floatFromInt(trials));
    const avg_throughput = file_size_mb / (avg_time / 1000.0);
    const std_dev = calculateStdDev(durations.items, avg_time);

    print("{d:<5} bytes    {d:>8.3} ms    {d:>10.2} MB/s    {d:>8.3} ms\n", .{
        buffer_size,
        avg_time,
        avg_throughput,
        std_dev,
    });
}

/// Clean up test file
fn cleanupTestFile(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(io, path) catch |err| {
        if (err != error.FileNotFound) {
            print("Warning: Could not delete test file: {}\n", .{err});
        }
    };
}
