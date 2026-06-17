const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len != 3) {
        std.debug.print("Usage: {s} <offset> <read-size>\n", .{args[0]});
        std.debug.print("Example: {s} 50M 4K\n", .{args[0]});
        return error.InvalidArgs;
    }

    const offset = try parseSize(args[1]);
    const readSize = try parseSize(args[2]);
    const fileSize = 100 * 1024 * 1024; // 100 MiB
    const filePath = "/tmp/temp_read_slice.dat";

    if (offset + readSize > fileSize) {
        std.debug.print("Error: offset + read-size exceeds file size.\n", .{});
        return error.ReadRangeExceedsFileSize;
    }

    // Generate test file
    std.debug.print("Generating 100MB test file...\n", .{});
    try createRandomFile(init.io, filePath, fileSize);
    defer {
        std.Io.Dir.cwd().deleteFile(init.io, filePath) catch {};
    }

    const speed_unbuffered = try benchmarkPositional(
        init.io,
        filePath,
        offset,
        readSize,
        allocator,
    );
    const speed_buffered = try benchmarkSequentialBuffered(
        init.io,
        filePath,
        offset,
        readSize,
        allocator,
    );
    const speed_seek = try benchmarkPositionalDirect(
        init.io,
        filePath,
        offset,
        readSize,
        allocator,
    );

    std.debug.print("\n- Results -\n", .{});
    std.debug.print(
        "Sequential (full read) speed:    {d:>8.2} MiB/s\n",
        .{speed_unbuffered},
    );
    std.debug.print(
        "Sequential (buffered)  speed:    {d:>8.2} MiB/s\n",
        .{speed_buffered},
    );
    std.debug.print(
        "Positional             speed:    {d:>8.2} MiB/s\n",
        .{speed_seek},
    );
}

// Read the whole file then extract the slice
fn benchmarkPositional(
    io: std.Io,
    path: []const u8,
    offset: usize,
    size: usize,
    allocator: std.mem.Allocator,
) !f64 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    const stat = try file.stat(io);
    const buffer = try allocator.alloc(u8, stat.size);
    defer allocator.free(buffer);

    const t_start = std.Io.Timestamp.now(io, .awake);

    _ = try file.readPositionalAll(io, buffer, 0);

    const slice = buffer[offset .. offset + size];
    std.mem.doNotOptimizeAway(slice);

    const elapsed_ns: u64 = @intCast(t_start.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds);
    return bytesPerSecond(size, elapsed_ns);
}

// Read in chunks and stop when the target range is covered
fn benchmarkSequentialBuffered(
    io: std.Io,
    path: []const u8,
    offset: usize,
    size: usize,
    allocator: std.mem.Allocator,
) !f64 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    const buffer_size = @max(4096, size);
    const buffer = try allocator.alloc(u8, buffer_size);
    defer allocator.free(buffer);

    var total_read: usize = 0;
    var matched: bool = false;
    const t_start = std.Io.Timestamp.now(io, .awake);

    while (!matched) {
        const n = file.readStreaming(io, &.{buffer}) catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        if (n == 0) break;

        const current_offset = total_read;
        const next_offset = total_read + n;

        if (offset >= current_offset and offset + size <= next_offset) {
            const start = offset - current_offset;
            const slice = buffer[start .. start + size];
            std.mem.doNotOptimizeAway(slice);
            matched = true;
        }

        total_read += n;
    }

    const elapsed_ns: u64 = @intCast(t_start.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds);
    return bytesPerSecond(size, elapsed_ns);
}

// Read directly at the target offset using positional I/O
fn benchmarkPositionalDirect(
    io: std.Io,
    path: []const u8,
    offset: usize,
    size: usize,
    allocator: std.mem.Allocator,
) !f64 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    const buffer = try allocator.alloc(u8, size);
    defer allocator.free(buffer);

    const t_start = std.Io.Timestamp.now(io, .awake);

    _ = try file.readPositionalAll(io, buffer, offset);

    std.mem.doNotOptimizeAway(buffer);

    const elapsed_ns: u64 = @intCast(t_start.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds);
    return bytesPerSecond(size, elapsed_ns);
}

fn parseSize(text: []const u8) !usize {
    if (text.len == 0) return error.InvalidSize;
    const last = text[text.len - 1];
    const is_suffix = (last >= 'A' and last <= 'Z');
    const num_part = if (is_suffix) text[0 .. text.len - 1] else text;
    const base = try std.fmt.parseInt(usize, num_part, 10);
    return switch (last) {
        'K' => base * 1024,
        'M' => base * 1024 * 1024,
        'G' => base * 1024 * 1024 * 1024,
        else => base,
    };
}

fn bytesPerSecond(bytes: usize, ns: u64) f64 {
    if (ns == 0) return 0.0;
    const mib = @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0);
    const seconds = @as(f64, @floatFromInt(ns)) / 1_000_000_000.0;
    return mib / seconds;
}

fn createRandomFile(io: std.Io, path: []const u8, size: usize) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);

    var seed_bytes: [8]u8 = undefined;
    io.random(&seed_bytes);
    var prng = std.Random.DefaultPrng.init(@bitCast(seed_bytes));
    const rand = prng.random();

    const charset = "abcdefghijklmnopqrstuvwxyz1234567890 \n";
    var buf: [4096]u8 = undefined;
    var total: usize = 0;

    while (total < size) {
        const to_write = @min(buf.len, size - total);
        for (buf[0..to_write]) |*b| {
            b.* = charset[rand.uintLessThan(usize, charset.len)];
        }
        try file.writeStreamingAll(io, buf[0..to_write]);
        total += to_write;
    }
}
