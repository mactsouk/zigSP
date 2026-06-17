/// scheduler.zig — the poll()-based main event loop
const std = @import("std");
const posix = std.posix;
const log = std.log.scoped(.scheduler);
const Job = @import("schedule.zig").Job;
const Schedule = @import("schedule.zig").Schedule;
const signals = @import("signals.zig");
const repl = @import("repl.zig");
const cfg = @import("config.zig");

// ─── Constants ────────────────────────────────────────────────────────────────

const TICK_MS: i32 = 1000;
const SHELL: [*:0]const u8 = "/bin/sh";
const CHILD_ENV = [_:null]?[*:0]const u8{
    "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
};

// ─── Public entry point ───────────────────────────────────────────────────────

pub fn run(ctx: *repl.Context) void {
    log.info("scheduler running with {d} job(s) — type 'help' for commands", .{ctx.schedule.len});

    repl.printPrompt(ctx.io);

    var fds = [1]posix.pollfd{.{
        .fd = posix.STDIN_FILENO,
        .events = posix.POLL.IN,
        .revents = 0,
    }};

    while (signals.isRunning()) {
        const ready = posix.poll(&fds, TICK_MS) catch |err| {
            if (err != error.Interrupted) {
                log.err("poll: {s}", .{@errorName(err)});
            }
            continue;
        };

        if (ready > 0 and (fds[0].revents & posix.POLL.IN) != 0) {
            const keep = repl.dispatch(ctx);
            if (!keep) break;
            continue;
        }

        tick(ctx.schedule);

        if (signals.shouldReload()) {
            const before = ctx.schedule.len;
            cfg.reload(ctx.schedule, ctx.io, ctx.cfg_path);
            signals.clearReload();
            stdoutPrint(ctx.io, "\n[reload] {d} job(s) (was {d})\nzcron> ", .{ ctx.schedule.len, before });
        }
    }

    log.info("scheduler stopped", .{});
    std.Io.File.stdout().writeStreamingAll(ctx.io, "\n") catch {};
}

// ─── Scheduler tick ───────────────────────────────────────────────────────────

fn tick(schedule: *Schedule) void {
    const now = unixNow();
    for (schedule.slice()) |*job| {
        if (!job.isDue(now)) continue;
        log.info("spawning: {s}", .{job.command()});
        spawnJob(job);
        job.last_run = now;
    }
}

// ─── Job spawning ─────────────────────────────────────────────────────────────

pub fn spawnJob(job: *const Job) void {
    const pid = std.c.fork();
    if (pid < 0) {
        log.err("fork failed for '{s}'", .{job.command()});
        return;
    }

    if (pid != 0) return;

    execCommand(job.command());
    std.c._exit(127);
}

fn execCommand(cmd: [:0]const u8) void {
    const argv = [_:null]?[*:0]const u8{ SHELL, "-c", cmd.ptr };
    _ = std.c.execve(SHELL, &argv, &CHILD_ENV);
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

fn unixNow() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return ts.sec;
}

fn stdoutPrint(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    std.Io.File.stdout().writeStreamingAll(io, s) catch {};
}
