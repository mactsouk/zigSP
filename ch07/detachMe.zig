const std = @import("std");
const posix = std.posix;

var g_running: bool = true;

// Derive the signal parameter type from posix.Sigaction itself so this
// compiles on any target without relying on auto-generated type names.
const signal_t = blk: {
    const handler_fn_ptr_opt = @FieldType(@FieldType(posix.Sigaction, "handler"), "handler");
    const handler_fn_ptr = @typeInfo(handler_fn_ptr_opt).optional.child;
    const handler_fn = @typeInfo(handler_fn_ptr).pointer.child;
    break :blk @typeInfo(handler_fn).@"fn".params[0].type.?;
};

fn onSigterm(_: signal_t) callconv(.c) void {
    @atomicStore(bool, &g_running, false, .release);
}

fn detach() !void {
    // First fork: detach from the terminal and let the shell continue.
    const pid = std.c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid > 0) std.c.exit(0);

    // Become a new session leader with no controlling terminal.
    if (std.c.setsid() < 0) return error.SetsidFailed;

    // Second fork: the grandchild is not a session leader, so it can never
    // accidentally acquire a controlling terminal by opening a tty device
    // (required on System V-derived systems; harmless on Linux).
    const pid2 = std.c.fork();
    if (pid2 < 0) return error.ForkFailed;
    if (pid2 > 0) std.c.exit(0);

    if (std.c.chdir("/") < 0) return error.ChdirFailed;

    const dev_null = std.c.openat(
        std.c.AT.FDCWD,
        "/dev/null",
        .{ .ACCMODE = .RDWR },
    );
    if (dev_null < 0) return error.OpenDevNullFailed;

    if (std.c.dup2(dev_null, std.c.STDIN_FILENO) < 0)
        return error.Dup2Failed;
    if (std.c.dup2(dev_null, std.c.STDOUT_FILENO) < 0)
        return error.Dup2Failed;
    if (std.c.dup2(dev_null, std.c.STDERR_FILENO) < 0)
        return error.Dup2Failed;

    if (dev_null > std.c.STDERR_FILENO) {
        _ = std.c.close(dev_null);
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const target_file = "/tmp/watch_me.txt";
    const log_file = "/tmp/background_process.log";

    const sa = posix.Sigaction{
        .handler = .{ .handler = onSigterm },
        .mask = std.mem.zeroes(posix.sigset_t),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.TERM, &sa, null);

    {
        const f = try std.Io.Dir.cwd().createFile(io, target_file, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "Started.\n");
    }

    try detach();

    var last_mtime: i96 = 0;
    while (@atomicLoad(bool, &g_running, .acquire)) {
        const file = std.Io.Dir.cwd().openFile(io, target_file, .{}) catch {
            try std.Io.sleep(io, std.Io.Duration.fromSeconds(1), .awake);
            continue;
        };
        defer file.close(io);
        const stat = try file.stat(io);

        const mtime_ns: i96 = stat.mtime.nanoseconds;
        if (mtime_ns > last_mtime) {
            last_mtime = mtime_ns;
            const fsize = stat.size;
            const content = try allocator.alloc(u8, fsize);
            defer allocator.free(content);
            _ = try file.readPositionalAll(io, content, 0);

            const log = try std.Io.Dir.cwd().createFile(
                io,
                log_file,
                .{ .truncate = false },
            );
            defer log.close(io);

            var buf: [8192]u8 = undefined;
            var ts: std.c.timespec = undefined;
            _ = std.c.clock_gettime(.REALTIME, &ts);
            const text = try std.fmt.bufPrint(
                &buf,
                "[{d}] File update detected:\n{s}\n",
                .{ ts.sec, content },
            );

            try log.writeStreamingAll(io, text);
        }
        try std.Io.sleep(io, std.Io.Duration.fromSeconds(1), .awake);
    }
}
