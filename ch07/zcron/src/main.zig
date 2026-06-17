/// main.zig — zcron entry point
const std = @import("std");
const posix = std.posix;
const signals = @import("signals.zig");
const cfg = @import("config.zig");
const schedule = @import("schedule.zig");
const scheduler = @import("scheduler.zig");
const repl = @import("repl.zig");

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const io = init.io;

    signals.installAll();

    const explicit = parseCfgPath(init);
    const explicit_owned: ?[]u8 = if (explicit) |p| try alloc.dupe(u8, p) else null;
    defer if (explicit_owned) |p| alloc.free(p);

    const default_path = try defaultConfigPath(alloc, init);
    defer alloc.free(default_path);
    const path: []const u8 = explicit_owned orelse default_path;

    var sched = schedule.Schedule{};
    cfg.load(&sched, io, path) catch |err| {
        std.log.warn("cannot load '{s}' ({s}); using built-in defaults", .{ path, @errorName(err) });
        try cfg.loadDefaults(&sched);
    };

    if (sched.len == 0) {
        std.log.err("schedule is empty — nothing to do", .{});
        return;
    }

    var ctx = repl.Context{
        .io = io,
        .schedule = &sched,
        .cfg_path = path,
        .start_time = unixNow(),
        .spawn_fn = scheduler.spawnJob,
    };
    scheduler.run(&ctx);
}

/// Return the first CLI argument, or null.
fn parseCfgPath(init: std.process.Init) ?[]const u8 {
    var iter = init.minimal.args.iterate();
    defer iter.deinit();
    _ = iter.next(); // skip argv[0]
    return iter.next();
}

/// Build the default config path: ~/.config/zcron/zcron.conf.
/// Falls back to ./zcron.conf if $HOME is not set.
fn defaultConfigPath(alloc: std.mem.Allocator, init: std.process.Init) ![]const u8 {
    const home = init.environ_map.get("HOME") orelse
        return alloc.dupe(u8, "zcron.conf");
    return std.fs.path.join(alloc, &.{ home, ".config", "zcron", "zcron.conf" });
}

fn unixNow() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return ts.sec;
}
