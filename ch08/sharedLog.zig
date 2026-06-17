const std = @import("std");

const Thread = std.Thread;

const LogContext = struct {
    io: std.Io,
    file: std.Io.File,
    mutex: *std.Io.Mutex,
    tID: usize,
};

fn threadLog(ctx: *LogContext) void {
    var buf: [128]u8 = undefined;
    const text = std.fmt.bufPrint(
        &buf,
        "[Thread {}]: value = {}\n",
        .{ ctx.tID, ctx.tID * 10 },
    ) catch return;

    ctx.mutex.lock(ctx.io) catch return;
    defer ctx.mutex.unlock(ctx.io);
    ctx.file.writeStreamingAll(ctx.io, text) catch {};
}

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = init.io;

    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    if (argv.len < 2) {
        std.debug.print("Usage: {s} <log_file_path>\n", .{argv[0]});
        return error.InvalidArguments;
    }

    const log_path = argv[1];
    const log_file = try std.Io.Dir.cwd().createFile(
        io,
        log_path,
        .{ .truncate = true },
    );
    defer log_file.close(io);

    var file_mutex: std.Io.Mutex = .init;
    const thread_count = 4;

    const threads = try allocator.alloc(Thread, thread_count);
    defer allocator.free(threads);

    const contexts = try allocator.alloc(LogContext, thread_count);
    defer allocator.free(contexts);

    for (0..thread_count) |i| {
        contexts[i] = LogContext{
            .io = io,
            .file = log_file,
            .mutex = &file_mutex,
            .tID = i,
        };
        threads[i] = try Thread.spawn(.{}, threadLog, .{&contexts[i]});
    }

    for (threads) |t| t.join();
    std.debug.print("Logging complete. Written to: {s}\n", .{log_path});
}
