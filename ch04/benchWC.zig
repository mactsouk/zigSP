const std = @import("std");

const Counts = struct {
    lines: usize,
    words: usize,
    bytes: usize,
};

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;

    // 1. SETUP STDOUT
    var stdout_buf: [4096]u8 = undefined;
    var stdout_impl = std.Io.File.stdout().writer(init.io, &stdout_buf);
    const stdout = &stdout_impl.interface;

    // 2. SETUP DATA
    const data_size = 100 * 1024 * 1024; // 100 MB
    try stdout.print("Allocating 100MB of test data...\n", .{});
    try stdout.flush();

    const buffer = try allocator.alloc(u8, data_size);
    defer allocator.free(buffer);

    var prng = std.Random.DefaultPrng.init(0);
    const rand = prng.random();

    for (buffer) |*b| {
        const r = rand.int(u8) % 100;
        if (r < 10) {
            b.* = '\n'; // 10% newlines
        } else if (r < 30) {
            b.* = ' '; // 20% spaces
        } else {
            b.* = 'a' + (r % 26); // 70% letters
        }
    }

    // 3. WARMUP
    _ = countScalar(buffer);
    _ = countSimd(buffer);

    // 4. BENCHMARK SCALAR
    try stdout.print("Benchmarking Scalar implementation...\n", .{});
    try stdout.flush();
    var t_start = std.Io.Timestamp.now(init.io, .awake);
    const res_scalar = countScalar(buffer);
    const time_scalar: u64 = @intCast(t_start.durationTo(std.Io.Timestamp.now(init.io, .awake)).nanoseconds);

    // 5. BENCHMARK SIMD
    try stdout.print("Benchmarking SIMD implementation...\n", .{});
    try stdout.flush();
    t_start = std.Io.Timestamp.now(init.io, .awake);
    const res_simd = countSimd(buffer);
    const time_simd: u64 = @intCast(t_start.durationTo(std.Io.Timestamp.now(init.io, .awake)).nanoseconds);

    // 6. VERIFY
    if (res_scalar.lines != res_simd.lines or res_scalar.words != res_simd.words) {
        try stdout.print("\nERROR: Mismatch!\n", .{});
        try stdout.print("Scalar: {} lines, {} words\n", .{ res_scalar.lines, res_scalar.words });
        try stdout.print("SIMD:   {} lines, {} words\n", .{ res_simd.lines, res_simd.words });
        try stdout.flush();
        return;
    }

    // 7. REPORT
    const scalar_gb_s = (@as(f64, @floatFromInt(data_size)) / @as(f64, @floatFromInt(time_scalar))) * 1.0e9 / 1024.0 / 1024.0 / 1024.0;
    const simd_gb_s = (@as(f64, @floatFromInt(data_size)) / @as(f64, @floatFromInt(time_simd))) * 1.0e9 / 1024.0 / 1024.0 / 1024.0;

    try stdout.print("\nResults (100MB input):\n", .{});
    try stdout.print("------------------------------------------------\n", .{});
    try stdout.print("Scalar: {d:.4} s  |  {d:.4} GB/s\n", .{ @as(f64, @floatFromInt(time_scalar)) / 1e9, scalar_gb_s });
    try stdout.print("SIMD:   {d:.4} s  |  {d:.4} GB/s\n", .{ @as(f64, @floatFromInt(time_simd)) / 1e9, simd_gb_s });
    try stdout.print("------------------------------------------------\n", .{});
    try stdout.print("Speedup: {d:.2}x\n", .{simd_gb_s / scalar_gb_s});
    try stdout.flush();
}

fn countScalar(buffer: []const u8) Counts {
    var lines: usize = 0;
    var words: usize = 0;
    var in_word = false;

    for (buffer) |c| {
        if (c == '\n') lines += 1;

        const is_space = std.ascii.isWhitespace(c);
        if (!is_space and !in_word) {
            in_word = true;
            words += 1;
        } else if (is_space) {
            in_word = false;
        }
    }
    return Counts{ .lines = lines, .words = words, .bytes = buffer.len };
}

fn countSimd(buffer: []const u8) Counts {
    var lines: usize = 0;
    var words: usize = 0;

    const VSize = 32;
    const Vector = @Vector(VSize, u8);
    const U1Vec = @Vector(VSize, u1);

    const ones_u1: U1Vec = @splat(1);
    const zeros_u1: U1Vec = @splat(0);
    const space: Vector = @splat(' ');
    const tab: Vector = @splat(9);
    const cr: Vector = @splat(13);
    const nl: Vector = @splat('\n');

    var i: usize = 0;
    var prev_was_space: u32 = 1;

    // 1. Vector Loop
    while (i + VSize <= buffer.len) : (i += VSize) {
        const v: Vector = buffer[i..][0..VSize].*;

        // Count Lines
        const is_nl = v == nl;
        const nl_bits: u32 = @bitCast(@select(u1, is_nl, ones_u1, zeros_u1));
        lines += @popCount(nl_bits);

        // Count Words
        const is_white = (v == space) | ((v >= tab) & (v <= cr));
        const curr_bits: u32 = @bitCast(@select(u1, is_white, ones_u1, zeros_u1));

        // Transition Logic
        const prev_bits = (curr_bits << 1) | prev_was_space;
        const word_starts = (~curr_bits) & prev_bits;
        words += @popCount(word_starts);

        prev_was_space = curr_bits >> 31;
    }

    // 2. Scalar Tail
    while (i < buffer.len) : (i += 1) {
        const c = buffer[i];
        if (c == '\n') lines += 1;
        const is_space = std.ascii.isWhitespace(c);
        const is_space_int: u32 = if (is_space) 1 else 0;

        if (!is_space and prev_was_space == 1) {
            words += 1;
        }
        prev_was_space = is_space_int;
    }

    return Counts{ .lines = lines, .words = words, .bytes = buffer.len };
}
