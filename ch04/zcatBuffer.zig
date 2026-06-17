const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const stdout_file = std.Io.File.stdout();
    const stderr_file = std.Io.File.stderr();

    // 1. SETUP BUFFERING
    var stdout_buf: [4096]u8 = undefined;
    var stdout_impl = stdout_file.writer(init.io, &stdout_buf);
    const stdout = &stdout_impl.interface;

    var stderr_impl = stderr_file.writer(init.io, &.{});
    const stderr = &stderr_impl.interface;

    // 2. DETECT TTY
    const is_terminal = try stdout_file.isTty(init.io);

    const args = try init.minimal.args.toSlice(allocator);

    if (args.len == 1) {
        try catStream(init.io, std.Io.File.stdin(), stdout, is_terminal);
    } else {
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const path = args[i];
            const file = std.Io.Dir.cwd().openFile(init.io, path, .{}) catch |err| {
                const msg = try std.fmt.allocPrint(
                    allocator,
                    "cat: {s}: {s}\n",
                    .{ path, @errorName(err) },
                );
                try stderr.writeAll(msg);
                continue;
            };
            defer file.close(init.io);
            try catStream(init.io, file, stdout, is_terminal);
        }
    }

    try stdout.flush();
}

fn catStream(
    io: std.Io,
    reader: std.Io.File,
    writer: anytype,
    line_buffer: bool,
) !void {
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = reader.readStreaming(io, &.{&buf}) catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        if (n == 0) break;

        const chunk = buf[0..n];
        try writer.writeAll(chunk);

        // SMART BUFFERING LOGIC:
        // If we are in "Terminal Mode" AND we see a newline, flush immediately.
        if (line_buffer) {
            if (std.mem.indexOfScalar(u8, chunk, '\n') != null) {
                try writer.flush();
            }
        }
    }
}
