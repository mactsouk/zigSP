const std = @import("std");
const Thread = std.Thread;

const ThreadArgs = struct {
    io: std.Io,
    counter: *usize,
    increments: usize,
    file_mutex: *std.Io.Mutex,
    logFile: *std.Io.File,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    if (argv.len != 3) {
        std.debug.print("Usage: {s} <logFile> <nThreads>\n", .{argv[0]});
        return error.InvalidArguments;
    }

    const logPath = argv[1];
    const nThreads = try std.fmt.parseInt(usize, argv[2], 10);
    const increments: usize = 100_000;
    var counter: usize align(std.atomic.cache_line) = 0;

    var file_mutex: std.Io.Mutex = .init;
    var logFile = try std.Io.Dir.cwd().createFile(io, logPath, .{});
    defer logFile.close(io);

    const threads = try allocator.alloc(Thread, nThreads);
    defer allocator.free(threads);
    for (threads) |*t| {
        t.* = try Thread.spawn(.{}, threadMain, .{ThreadArgs{
            .io = io,
            .counter = &counter,
            .increments = increments,
            .file_mutex = &file_mutex,
            .logFile = &logFile,
        }});
    }

    for (threads) |t| t.join();
    const final = @atomicLoad(usize, &counter, .seq_cst);
    std.debug.print(
        "Done: attempted to log {} * {} increments to {s}\n",
        .{ nThreads, increments, logPath },
    );
    std.debug.print(
        "Final counter value (expected {}): {}\n",
        .{ nThreads * increments, final },
    );
}

fn threadMain(args: ThreadArgs) void {
    var buf: [32]u8 = undefined;
    var i: usize = 0;

    while (i < args.increments) : (i += 1) {
        const previous = @atomicRmw(
            usize,
            args.counter,
            .Add,
            1,
            .seq_cst,
        );
        const new_val = previous + 1;
        const line = std.fmt.bufPrint(&buf, "{}\n", .{new_val}) catch
            continue;

        // Lines may appear out of order: the lock is
        // acquired after the increment, so another thread can
        // win the lock and write a higher value first. Ordering would
        // require holding the lock across both
        // the increment and the write.
        args.file_mutex.lock(args.io) catch return;
        defer args.file_mutex.unlock(args.io);
        args.logFile.writeStreamingAll(args.io, line) catch {};
    }
}
