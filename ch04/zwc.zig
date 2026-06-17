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
    var buffer: [16 * 1024]u8 = undefined;

    var lines: usize = 0;
    var words: usize = 0;
    var bytes: usize = 0;
    var in_word = false;

    while (true) {
        const n = file.readStreaming(io, &.{&buffer}) catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        if (n == 0) break;

        bytes += n;

        for (buffer[0..n]) |c| {
            if (c == '\n') {
                lines += 1;
            }
            if (std.ascii.isWhitespace(c)) {
                in_word = false;
            } else if (!in_word) {
                in_word = true;
                words += 1;
            }
        }
    }

    return Counts{ .lines = lines, .words = words, .bytes = bytes };
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
