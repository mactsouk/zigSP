const std = @import("std");
const c = @cImport({
    @cInclude("signal.h");
    @cInclude("unistd.h");
});

var randomValue = std.atomic.Value(i32).init(0);
var sRunning = std.atomic.Value(usize).init(0);
var newValueRequested = std.atomic.Value(bool).init(false);
var uptimeRequested = std.atomic.Value(bool).init(false);

fn handle_sigusr1(_: c_int) callconv(.c) void {
    newValueRequested.store(true, .monotonic);
}

fn handle_sigusr2(_: c_int) callconv(.c) void {
    uptimeRequested.store(true, .monotonic);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    _ = c.signal(c.SIGUSR1, handle_sigusr1);
    _ = c.signal(c.SIGUSR2, handle_sigusr2);

    std.debug.print(
        "Use -USR1 <pid> and -USR2 <pid> to send signals.\n",
        .{},
    );
    std.debug.print("PID: {}\n", .{c.getpid()});

    while (true) {
        try std.Io.sleep(io, std.Io.Duration.fromSeconds(2), .awake);
        _ = sRunning.fetchAdd(2, .seq_cst);
        if (newValueRequested.load(.seq_cst)) {
            newValueRequested.store(false, .seq_cst);
            var buf: [4]u8 = undefined;
            io.random(&buf);
            randomValue.store(
                std.mem.readInt(i32, &buf, .little),
                .seq_cst,
            );
            std.debug.print(
                "randomValue: {d}\n",
                .{randomValue.load(.seq_cst)},
            );
        }
        if (uptimeRequested.load(.seq_cst)) {
            uptimeRequested.store(false, .seq_cst);
            std.debug.print(
                "Uptime: {d} seconds\n",
                .{sRunning.load(.seq_cst)},
            );
        }
    }
}
