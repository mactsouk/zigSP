const std = @import("std");
const print = std.debug.print;

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 4) {
        print("Usage: {s} <fsize_mb> <trials> [buffer_size1 ...]\n", .{args[0]});
        print("Example: {s} 100 5 128 1024 4096 16384\n", .{args[0]});
        return;
    }

    const file_size_mb = try std.fmt.parseUnsigned(usize, args[1], 10);
    const trials = try std.fmt.parseUnsigned(usize, args[2], 10);
    const buffer_sizes = args[3..];

    const test_file_path = "/tmp/benchmark_testfile.tmp";

    // Generate the file
    try generateTestFile(init.io, allocator, test_file_path, file_size_mb);
    defer cleanupTestFile(init.io, test_file_path);

    // Print benchmark header
    print("\nFile Reading Benchmark - {d} MB File - {d} Trials\n", .{
        file_size_mb,
        trials,
    });
    print("========================================================================\n", .{});
    print("{s:<15} {s:<15} {s:<20} {s:<15}\n", .{
        "Buffer Size",
        "Avg Time (ms)",
        "Avg Throughput",
        "Std Dev",
    });
    print("------------------------------------------------------------------------\n", .{});

    for (buffer_sizes) |size_str| {
        const buffer_size = std.fmt.parseInt(usize, size_str, 10) catch |err| {
            print("Skipping invalid buffer size '{s}': {}\n", .{ size_str, err });
            continue;
        };

        try benchmarkBufferSize(init.io, allocator, test_file_path, buffer_size, trials);
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
    return @sqrt(variance);
}

/// Generate a test file with random printable characters
fn generateTestFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    size_mb: usize,
) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);

    const size_bytes = size_mb * 1024 * 1024;
    const chunk_size = 16 * 1024; // 16KB chunks
    const buffer = try allocator.alloc(u8, chunk_size);
    defer allocator.free(buffer);

    var seed_bytes: [8]u8 = undefined;
    io.random(&seed_bytes);
    var prng = std.Random.DefaultPrng.init(@bitCast(seed_bytes));
    const rand = prng.random();

    var written: usize = 0;
    while (written < size_bytes) {
        // Fill buffer with printable ASCII (32-126)
        for (buffer) |*byte| {
            byte.* = rand.intRangeAtMost(u8, 32, 126);
        }

        const remaining = size_bytes - written;
        const to_write = @min(buffer.len, remaining);

        try file.writeStreamingAll(io, buffer[0..to_write]);
        written += to_write;
    }
}

fn cleanupTestFile(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(io, path) catch |err| {
        print("Warning: Could not delete test file: {}\n", .{err});
    };
}

/// Benchmark a specific buffer size across multiple trials
fn benchmarkBufferSize(
    io: std.Io,
    allocator: std.mem.Allocator,
    file_path: []const u8,
    buffer_size: usize,
    trials: usize,
) !void {
    const file_check = try std.Io.Dir.cwd().openFile(
        io,
        file_path,
        .{},
    );
    const file_size = (try file_check.stat(io)).size;
    file_check.close(io);

    const file_size_mb_float = @as(
        f64,
        @floatFromInt(file_size),
    ) / (1024.0 * 1024.0);

    const buffer = try allocator.alloc(u8, buffer_size);
    defer allocator.free(buffer);

    var durations = try std.ArrayListUnmanaged(f64).initCapacity(allocator, trials);
    defer durations.deinit(allocator);

    var total_time_ms: f64 = 0;
    for (0..trials) |_| {
        const file = try std.Io.Dir.cwd().openFile(io, file_path, .{});
        defer file.close(io);

        const t_start = std.Io.Timestamp.now(io, .awake);
        var total_read: usize = 0;

        while (true) {
            const bytes_read = file.readStreaming(
                io,
                &.{buffer},
            ) catch |err| {
                if (err == error.EndOfStream) break;
                return err;
            };
            if (bytes_read == 0) break;
            total_read += bytes_read;
        }

        // durationTo returns i96 nanoseconds; safe to @intCast to
        // u64 because the .awake (monotonic) clock never goes backwards.
        const elapsed_ns: u64 = @intCast(t_start.durationTo(
            std.Io.Timestamp.now(io, .awake),
        ).nanoseconds);
        const elapsed_ms = @as(
            f64,
            @floatFromInt(elapsed_ns),
        ) / 1_000_000.0;

        try durations.append(allocator, elapsed_ms);
        total_time_ms += elapsed_ms;
    }

    const avg_time_ms = total_time_ms / @as(f64, @floatFromInt(trials));
    const avg_throughput = file_size_mb_float / (avg_time_ms / 1000.0);
    const std_dev_ms = calculateStdDev(durations.items, avg_time_ms);

    print("{d:<5} bytes    {d:>8.3} ms    {d:>10.2} MB/s    {d:>8.3} ms\n", .{
        buffer_size,
        avg_time_ms,
        avg_throughput,
        std_dev_ms,
    });
}
