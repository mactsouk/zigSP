const std = @import("std");

const Counts = struct {
    lines: usize,
    words: usize,
    bytes: usize,
};

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try init.minimal.args.toSlice(allocator);

    // 1. SETUP STDOUT (Buffered)
    var stdout_buf: [4096]u8 = undefined;
    var stdout_impl = std.Io.File.stdout().writer(init.io, &stdout_buf);
    const stdout = &stdout_impl.interface;

    // 2. SETUP STDERR (Unbuffered)
    var stderr_impl = std.Io.File.stderr().writer(init.io, &.{});
    const stderr = &stderr_impl.interface;

    var showLines = true;
    var showWords = true;
    var showBytes = true;
    var filenames_start: usize = 1;

    // 3. Parse Flags
    if (args.len > 1 and args[1].len > 0 and args[1][0] == '-') {
        showLines = false;
        showWords = false;
        showBytes = false;

        for (args[1][1..]) |c| {
            switch (c) {
                'l' => showLines = true,
                'w' => showWords = true,
                'c' => showBytes = true,
                else => {
                    try stderr.print("Unknown option: -{c}\n", .{c});
                    return;
                },
            }
        }
        filenames_start = 2;
    }

    var total = Counts{ .lines = 0, .words = 0, .bytes = 0 };
    var file_count: usize = 0;

    // 4. Process
    if (args.len <= filenames_start) {
        // Read from Stdin
        const counts = try processStream(init.io, std.Io.File.stdin());
        try printCounts(stdout, counts, "", showLines, showWords, showBytes);
    } else {
        // Read from Files
        for (args[filenames_start..]) |filePath| {
            const file = std.Io.Dir.cwd().openFile(init.io, filePath, .{}) catch |err| {
                try stderr.print("zwc: {s}: {s}\n", .{ filePath, @errorName(err) });
                continue;
            };
            defer file.close(init.io);

            const counts = try processStream(init.io, file);

            total.lines += counts.lines;
            total.words += counts.words;
            total.bytes += counts.bytes;
            file_count += 1;

            try printCounts(stdout, counts, filePath, showLines, showWords, showBytes);
        }

        if (file_count > 1) {
            try printCounts(stdout, total, "total", showLines, showWords, showBytes);
        }
    }

    // Flush stdout buffer
    try stdout.flush();
}

fn processStream(io: std.Io, file: std.Io.File) !Counts {
    // 64KB buffer for high throughput
    var buffer: [64 * 1024]u8 = undefined;

    var lines: usize = 0;
    var words: usize = 0;
    var bytes: usize = 0;

    // SIMD Configuration
    const VSize = 32;
    // @Vector(32, u8) requests 32-byte vectorization; on x86-64 with
    // AVX2 this is one 256-bit instruction, on arm64 two 128-bit NEON ops.
    // Use -mcpu=native to enable the widest available SIMD.
    const Vector = @Vector(VSize, u8);
    const U1Vec = @Vector(VSize, u1);

    // Helpers
    const ones_u1: U1Vec = @splat(1);
    const zeros_u1: U1Vec = @splat(0);
    const space_char: Vector = @splat(' ');
    const tab_char: Vector = @splat('\t');
    const cr_char: Vector = @splat('\r');
    const nl_char: Vector = @splat('\n');

    var prev_was_space: u32 = 1;

    while (true) {
        const n = file.readStreaming(io, &.{&buffer}) catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        if (n == 0) break;
        bytes += n;

        var i: usize = 0;

        // 1. SIMD LOOP
        while (i + VSize <= n) : (i += VSize) {
            const v: Vector = buffer[i..][0..VSize].*;

            const is_nl = v == nl_char;
            const nl_bits: u32 = @bitCast(
                @select(u1, is_nl, ones_u1, zeros_u1),
            );
            lines += @popCount(nl_bits);

            const is_white = (v == space_char) |
                ((v >= tab_char) & (v <= cr_char));
            const curr_bits: u32 = @bitCast(
                @select(u1, is_white, ones_u1, zeros_u1),
            );
            const prev_bits = (curr_bits << 1) | prev_was_space;
            const word_starts = (~curr_bits) & prev_bits;
            words += @popCount(word_starts);
            prev_was_space = curr_bits >> 31;
        }

        // 2. SCALAR TAIL LOOP
        while (i < n) : (i += 1) {
            const c = buffer[i];
            if (c == '\n') lines += 1;

            const is_space = std.ascii.isWhitespace(c);
            const is_space_int: u32 = if (is_space) 1 else 0;

            if (!is_space and prev_was_space == 1) {
                words += 1;
            }
            prev_was_space = is_space_int;
        }
    }

    return Counts{
        .lines = lines,
        .words = words,
        .bytes = bytes,
    };
}

fn printCounts(
    writer: anytype,
    counts: Counts,
    filename: []const u8,
    showLines: bool,
    showWords: bool,
    showBytes: bool,
) !void {
    if (showLines) {
        try writer.print("{d: >12}", .{counts.lines});
    }
    if (showWords) {
        try writer.print("{d: >12}", .{counts.words});
    }
    if (showBytes) {
        try writer.print("{d: >12}", .{counts.bytes});
    }
    if (filename.len != 0) {
        try writer.print(" {s}", .{filename});
    }
    try writer.writeByte('\n');
}
