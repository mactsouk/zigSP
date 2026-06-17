const std = @import("std");

const c = @cImport({
    @cInclude("signal.h");
    @cInclude("unistd.h");
});

var running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true);

fn handle_sigint(_: c_int) callconv(.c) void {
    running.store(false, .seq_cst);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    _ = c.signal(c.SIGINT, handle_sigint);
    std.debug.print("Running... Ctrl+C to trigger SIGINT.\n", .{});

    while (running.load(.seq_cst)) {
        try std.Io.sleep(io, std.Io.Duration.fromSeconds(1), .awake);
    }
    std.debug.print("Caught SIGINT, exiting.\n", .{});
    std.process.exit(0);
}
