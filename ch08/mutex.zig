const std = @import("std");

var mutex: std.Io.Mutex = .init;
var counter: u32 = 0;

const ThreadArgs = struct { io: std.Io, id: usize };

fn incrementThread(args: ThreadArgs) void {
    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        mutex.lock(args.io) catch return; // Begin critical section
        counter += 1;
        mutex.unlock(args.io); // End critical section
    }

    std.debug.print("Thread {d} done.\n", .{args.id});
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const t1 = try std.Thread.spawn(
        .{},
        incrementThread,
        .{ThreadArgs{ .io = io, .id = 1 }},
    );
    const t2 = try std.Thread.spawn(
        .{},
        incrementThread,
        .{ThreadArgs{ .io = io, .id = 2 }},
    );

    t1.join();
    t2.join();

    std.debug.print("Final counter value: {d}\n", .{counter});
}
