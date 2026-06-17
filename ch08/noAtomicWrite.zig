const std = @import("std");
const Thread = std.Thread;

const ThreadArgs = struct {
    io: std.Io,
    counter_ptr: *usize,
    increments: usize,
    file_mutex_ptr: *std.Io.Mutex,
    logFile_ptr: *std.Io.File,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    if (argv.len < 3) {
        std.debug.print(
            "Usage: {s} <logPath> <nThreads>\n",
            .{argv[0]},
        );
        return error.InvalidArgs;
    }

    const logPath = argv[1];
    const nThreads = try std.fmt.parseInt(usize, argv[2], 10);
    const increments = 100_000;

    var counter: usize = 0;
    var logFile = try std.Io.Dir.cwd().createFile(io, logPath, .{});
    defer logFile.close(io);
    var file_mutex: std.Io.Mutex = .init;

    const threads = try allocator.alloc(Thread, nThreads);
    defer allocator.free(threads);
    for (threads) |*t| {
        t.* = try Thread.spawn(.{}, threadMain, .{ThreadArgs{
            .io = io,
            .counter_ptr = &counter,
            .increments = increments,
            .file_mutex_ptr = &file_mutex,
            .logFile_ptr = &logFile,
        }});
    }

    for (threads) |t| t.join();

    std.debug.print("Done: attempted to log {} * {} increments to {s}\n", .{
        nThreads, increments, logPath,
    });
    std.debug.print("Final counter value (expected {}): {}\n", .{
        nThreads * increments, counter,
    });
}

fn threadMain(args: ThreadArgs) void {
    var buf: [32]u8 = undefined;
    var i: usize = 0;
    while (i < args.increments) : (i += 1) {
        // This is *NOT* thread-safe!
        const new_val = args.counter_ptr.* + 1;
        args.counter_ptr.* = new_val;

        const line = std.fmt.bufPrint(&buf, "{}\n", .{new_val}) catch
            continue;
        args.file_mutex_ptr.lock(args.io) catch return;
        args.logFile_ptr.writeStreamingAll(args.io, line) catch {};
        args.file_mutex_ptr.unlock(args.io);
    }
}
