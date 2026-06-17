const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const stdout = std.Io.File.stdout();
    const stderr = std.Io.File.stderr();
    const args = try init.minimal.args.toSlice(allocator);

    if (args.len == 1) {
        // Pass the raw stdin file handle directly
        try catStream(init.io, std.Io.File.stdin(), stdout);
    } else {
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const path = args[i];
            const file = std.Io.Dir.cwd().openFile(
                init.io,
                path,
                .{},
            ) catch |err| {
                const msg = try std.fmt.allocPrint(
                    allocator,
                    "cat: {s}: {s}\n",
                    .{ path, @errorName(err) },
                );
                try stderr.writeStreamingAll(init.io, msg);
                continue;
            };
            defer file.close(init.io);

            try catStream(init.io, file, stdout);
        }
    }
}

fn catStream(
    io: std.Io,
    reader: std.Io.File,
    writer: std.Io.File,
) !void {
    var buf: [128]u8 = undefined;
    while (true) {
        const n = reader.readStreaming(io, &.{&buf}) catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        try writer.writeStreamingAll(io, buf[0..n]);
    }
}
