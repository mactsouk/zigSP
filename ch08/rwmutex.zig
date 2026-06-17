const std = @import("std");

var rwlock: std.Io.RwLock = .init;
var counter: u32 = 0;

const WriterArgs = struct { io: std.Io, id: usize };
const ReaderArgs = struct { io: std.Io, id: usize };

fn writerThread(args: WriterArgs) void {
    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        rwlock.lock(args.io) catch return;
        counter += 1;
        rwlock.unlock(args.io);
    }
    std.debug.print("Writer {d} done.\n", .{args.id});
}

fn readerThread(args: ReaderArgs) void {
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        rwlock.lockShared(args.io) catch return;
        const value = counter;
        rwlock.unlockShared(args.io);
        std.debug.print(
            "Reader {d} sees counter = {d}\n",
            .{ args.id, value },
        );
        std.Io.sleep(
            args.io,
            std.Io.Duration.fromMilliseconds(200),
            .awake,
        ) catch {};
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const writer = try std.Thread.spawn(
        .{},
        writerThread,
        .{WriterArgs{ .io = io, .id = 1 }},
    );
    const reader1 = try std.Thread.spawn(
        .{},
        readerThread,
        .{ReaderArgs{ .io = io, .id = 1 }},
    );
    const reader2 = try std.Thread.spawn(
        .{},
        readerThread,
        .{ReaderArgs{ .io = io, .id = 2 }},
    );

    writer.join();
    reader1.join();
    reader2.join();

    std.debug.print("Final counter value: {d}\n", .{counter});
}
