/// repl.zig — interactive REPL for zcron
const std = @import("std");
const posix = std.posix;
const Schedule = @import("schedule.zig").Schedule;
const signals = @import("signals.zig");
const cfg = @import("config.zig");

// ─── Context ──────────────────────────────────────────────────────────────────

pub const Context = struct {
    io: std.Io,
    schedule: *Schedule,
    cfg_path: []const u8,
    start_time: i64,
    spawn_fn: *const fn (*const @import("schedule.zig").Job) void,
};

// ─── I/O primitives ──────────────────────────────────────────────────────────

fn stdoutWrite(io: std.Io, s: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(io, s) catch {};
}

fn stdoutPrint(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    std.Io.File.stdout().writeStreamingAll(io, s) catch {};
}

/// Read one line from stdin into `buf`, returning a slice without the newline.
/// Returns null on EOF or read error.
fn stdinReadLine(buf: []u8) ?[]u8 {
    var i: usize = 0;
    while (i < buf.len) {
        var byte: [1]u8 = undefined;
        const n = posix.read(posix.STDIN_FILENO, &byte) catch return null;
        if (n == 0) return null; // EOF
        if (byte[0] == '\n') break;
        buf[i] = byte[0];
        i += 1;
    }
    return buf[0..i];
}

// ─── Entry point ─────────────────────────────────────────────────────────────

pub fn printPrompt(io: std.Io) void {
    stdoutWrite(io, "zcron> ");
}

pub fn dispatch(ctx: *Context) bool {
    var line_buf: [512]u8 = undefined;

    const raw = stdinReadLine(&line_buf) orelse return false;
    const line = std.mem.trim(u8, raw, " \t\r");

    if (line.len == 0) {
        printPrompt(ctx.io);
        return true;
    }

    const sp = std.mem.indexOfScalar(u8, line, ' ');
    const verb = if (sp) |i| line[0..i] else line;
    const rest = if (sp) |i| std.mem.trim(u8, line[i..], " \t") else "";

    const keep_running = runCommand(ctx, verb, rest);
    if (keep_running) printPrompt(ctx.io);
    return keep_running;
}

// ─── Command dispatch ─────────────────────────────────────────────────────────

fn runCommand(ctx: *Context, verb: []const u8, rest: []const u8) bool {
    if (eql(verb, "help")) {
        cmdHelp(ctx.io);
        return true;
    }
    if (eql(verb, "list")) {
        cmdList(ctx);
        return true;
    }
    if (eql(verb, "status")) {
        cmdStatus(ctx);
        return true;
    }
    if (eql(verb, "reload")) {
        cmdReload(ctx);
        return true;
    }
    if (eql(verb, "run")) {
        cmdRun(ctx, rest);
        return true;
    }
    if (eql(verb, "quit") or
        eql(verb, "exit"))
    {
        cmdQuit(ctx.io);
        return false;
    }

    stdoutPrint(ctx.io, "unknown command '{s}' — type 'help' for a list\n", .{verb});
    return true;
}

// ─── Individual commands ──────────────────────────────────────────────────────

fn cmdHelp(io: std.Io) void {
    stdoutWrite(io,
        \\Commands:
        \\  list          show all scheduled jobs and their timing
        \\  run <n>       force-run job #n right now
        \\  reload        reload the config file from disk
        \\  status        show uptime and job count
        \\  help          show this message
        \\  quit / exit   stop zcron gracefully
        \\
        \\Signals:
        \\  SIGHUP        same as 'reload'
        \\  SIGTERM       same as 'quit'
        \\
    );
}

fn cmdList(ctx: *Context) void {
    const now = unixNow();
    const jobs = ctx.schedule.slice();

    if (jobs.len == 0) {
        stdoutWrite(ctx.io, "  (no jobs scheduled)\n");
        return;
    }

    stdoutWrite(ctx.io, "  #  interval   last run       next run       command\n" ++
        "  -  ---------  -------------  -------------  ------------------------------\n");

    for (jobs, 0..) |*job, i| {
        const last_buf = fmtRelTime(now, job.last_run, false);
        const next_buf = fmtRelTime(now, job.last_run + @as(i64, @intCast(job.interval_sec)), true);

        stdoutPrint(ctx.io, "  {d}  {s:>8}   {s:<13}  {s:<13}  {s}\n", .{
            i,
            fmtInterval(job.interval_sec),
            last_buf.slice(),
            next_buf.slice(),
            truncate(job.command(), 40),
        });
    }
}

fn cmdRun(ctx: *Context, arg: []const u8) void {
    const idx = std.fmt.parseInt(usize, arg, 10) catch {
        stdoutPrint(ctx.io, "usage: run <job-number>  (got '{s}')\n", .{arg});
        return;
    };
    const jobs = ctx.schedule.slice();
    if (idx >= jobs.len) {
        stdoutPrint(ctx.io, "no job #{d}  (schedule has {d} job(s))\n", .{ idx, jobs.len });
        return;
    }
    stdoutPrint(ctx.io, "spawning job #{d}: {s}\n", .{ idx, jobs[idx].command() });
    ctx.spawn_fn(&jobs[idx]);
    jobs[idx].last_run = unixNow();
}

fn cmdReload(ctx: *Context) void {
    const before = ctx.schedule.len;
    cfg.reload(ctx.schedule, ctx.io, ctx.cfg_path);
    stdoutPrint(ctx.io, "reloaded — {d} job(s) (was {d})\n", .{ ctx.schedule.len, before });
}

fn cmdStatus(ctx: *Context) void {
    const now = unixNow();
    const elapsed = now - ctx.start_time;
    const h = @divTrunc(elapsed, 3600);
    const m = @divTrunc(@rem(elapsed, 3600), 60);
    const s = @rem(elapsed, 60);

    stdoutPrint(
        ctx.io,
        "  uptime : {d}h {d}m {d}s\n" ++
            "  jobs   : {d}\n" ++
            "  config : {s}\n",
        .{ h, m, s, ctx.schedule.len, ctx.cfg_path },
    );
}

fn cmdQuit(io: std.Io) void {
    stdoutWrite(io, "shutting down\n");
    signals.requestStop();
}

// ─── Formatting helpers ───────────────────────────────────────────────────────

const SmallBuf = struct {
    data: [24]u8 = undefined,
    used: usize = 0,

    fn slice(self: *const SmallBuf) []const u8 {
        return self.data[0..self.used];
    }
};

fn fmtRelTime(now: i64, ts: i64, is_future: bool) SmallBuf {
    var b = SmallBuf{};
    if (!is_future and ts == 0) {
        b.used = if (std.fmt.bufPrint(&b.data, "never", .{})) |s| s.len else |_| 0;
        return b;
    }
    const diff = if (is_future) ts - now else now - ts;
    if (diff <= 0) {
        const s = if (is_future) "now" else "just now";
        b.used = if (std.fmt.bufPrint(&b.data, "{s}", .{s})) |r| r.len else |_| 0;
    } else if (is_future) {
        b.used = if (std.fmt.bufPrint(&b.data, "in {d}s", .{diff})) |r| r.len else |_| 0;
    } else {
        b.used = if (std.fmt.bufPrint(&b.data, "{d}s ago", .{diff})) |r| r.len else |_| 0;
    }
    return b;
}

fn fmtInterval(secs: u64) [8]u8 {
    // Zig 0.16: var buf = [_]u8{' '} ** 8;
    var buf: [8]u8 = @splat(' ');
    if (secs < 60) {
        _ = std.fmt.bufPrint(&buf, "{d}s", .{secs}) catch {};
    } else if (secs < 3600) {
        _ = std.fmt.bufPrint(&buf, "{d}m{d}s", .{ secs / 60, secs % 60 }) catch {};
    } else {
        _ = std.fmt.bufPrint(&buf, "{d}h{d}m", .{ secs / 3600, (secs % 3600) / 60 }) catch {};
    }
    return buf;
}

fn truncate(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    return s[0 .. max - 3];
}

fn unixNow() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return ts.sec;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
