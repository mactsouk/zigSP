/// config.zig — load and reload a zcron schedule from a config file
///
/// File format (one job per line):
///   # comment lines and blank lines are ignored
///   <interval_seconds>  <shell command...>
const std = @import("std");
const Schedule = @import("schedule.zig").Schedule;
const log = std.log.scoped(.config);

// ─── Public API ───────────────────────────────────────────────────────────────

pub fn load(schedule: *Schedule, io: std.Io, path: []const u8) !void {
    schedule.reset();

    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var buf: [65536]u8 = undefined;
    const n = try file.readPositionalAll(io, &buf, 0);

    var lines = std.mem.splitScalar(u8, buf[0..n], '\n');
    var line_no: u32 = 0;
    while (lines.next()) |raw| {
        line_no += 1;
        const line = trimLine(raw);
        if (isBlankOrComment(line)) continue;

        parseLine(schedule, line) catch |err| {
            log.warn("config:{d}: skipping '{s}' — {s}", .{ line_no, line, @errorName(err) });
        };
    }

    log.info("loaded {d} job(s) from {s}", .{ schedule.len, path });
}

pub fn reload(schedule: *Schedule, io: std.Io, path: []const u8) void {
    log.info("reloading config from {s}", .{path});
    load(schedule, io, path) catch |err| {
        log.warn("reload failed ({s}), schedule unchanged", .{@errorName(err)});
    };
}

pub fn loadDefaults(schedule: *Schedule) !void {
    try schedule.addJob("/bin/date >> /tmp/zcron_alive.log", 60);
    log.info("no config found — using built-in default ({d} job)", .{schedule.len});
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

fn trimLine(raw: []const u8) []const u8 {
    const s = std.mem.trimEnd(u8, raw, "\r");
    return std.mem.trim(u8, s, " \t");
}

fn isBlankOrComment(line: []const u8) bool {
    return line.len == 0 or line[0] == '#';
}

fn parseLine(schedule: *Schedule, line: []const u8) !void {
    const ws = std.mem.indexOfAny(u8, line, " \t") orelse
        return error.MissingCommand;

    const interval = std.fmt.parseInt(u64, line[0..ws], 10) catch return error.BadInterval;
    if (interval == 0) return error.ZeroInterval;

    const cmd = std.mem.trim(u8, line[ws..], " \t");
    if (cmd.len == 0) return error.MissingCommand;

    try schedule.addJob(cmd, interval);
}
