/// forkExec.zig — running periodic tasks with fork and exec
///
/// This program demonstrates the Unix model for launching external commands:
///   1. fork()  — duplicate the current process
///   2. exec()  — replace the child's image with the target program
///
/// The parent process never blocks waiting for a command to finish.
/// Each command runs as an independent child process; the parent simply
/// checks the schedule on every tick and moves on.
const std = @import("std");

/// A single periodic task: a shell command and the seconds between runs.
const Task = struct {
    command: [:0]const u8,
    interval_sec: u64,
    last_run: i64 = 0,

    fn isDue(self: *const Task, now: i64) bool {
        return (now - self.last_run) >= @as(i64, @intCast(self.interval_sec));
    }
};

/// The fixed list of tasks we want to run periodically.
var tasks = [_]Task{
    .{ .command = "date", .interval_sec = 5 },
    .{
        .command = "echo 'hello from forkExec child'",
        .interval_sec = 10,
    },
    .{ .command = "ls /tmp", .interval_sec = 15 },
};

/// Spawn `command` in a child process by forking and exec-ing /bin/sh.
fn spawn(command: [:0]const u8) void {
    const pid = std.c.fork();
    if (pid < 0) {
        std.log.err("fork failed", .{});
        return;
    }

    if (pid != 0) {
        std.log.info("spawned pid {d}: {s}", .{ pid, command });
        return;
    }

    const argv = [_:null]?[*:0]const u8{
        "/bin/sh",
        "-c",
        command.ptr,
    };
    const envp = [_:null]?[*:0]const u8{
        "PATH=/usr/local/bin:/usr/bin:/bin",
    };
    _ = std.c.execve("/bin/sh", &argv, &envp);
    std.c._exit(127);
}

fn tick(now: i64) void {
    for (&tasks) |*task| {
        if (task.isDue(now)) {
            spawn(task.command);
            task.last_run = now;
        }
    }
}

fn unixNow() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return ts.sec;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    std.log.info("fork_exec starting — {d} task(s)", .{tasks.len});
    const RUN_FOR_SECS: i64 = 30;
    const start = unixNow();
    while (true) {
        const now = unixNow();
        if (now - start >= RUN_FOR_SECS) break;
        tick(now);
        try std.Io.sleep(io, std.Io.Duration.fromSeconds(1), .awake);
    }
    std.log.info("done", .{});
}
