const std = @import("std");
const Io = std.Io;
const Thread = std.Thread;
const AtomicUsize = std.atomic.Value(usize);

var thread_counter = AtomicUsize.init(0);

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = init.io;

    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    if (argv.len < 2) {
        std.debug.print("Usage: echo_server <port>\n", .{});
        return error.MissingPort;
    }

    const port = try std.fmt.parseInt(u16, argv[1], 10);
    const address = try Io.net.IpAddress.parseIp4("0.0.0.0", port);

    var server = try address.listen(io, .{});
    defer server.deinit(io);

    std.debug.print("Listening on 0.0.0.0:{d}\n", .{port});

    while (true) {
        const stream = server.accept(io) catch |err| {
            std.debug.print("Accept failed: {}\n", .{err});
            continue;
        };

        const thread_num = thread_counter.fetchAdd(1, .seq_cst);

        const thread = Thread.spawn(.{
            .allocator = allocator,
        }, handleConnection, .{
            io,
            stream,
            thread_num,
        }) catch |err| {
            std.debug.print("Failed to spawn thread: {}\n", .{err});
            stream.close(io);
            continue;
        };

        thread.detach();
    }
}

fn handleConnection(io: Io, stream: Io.net.Stream, thread_num: usize) void {
    std.debug.print("[Thread {d}] Accepted connection\n", .{thread_num});
    defer stream.close(io);

    var rbuf: [1024]u8 = undefined;
    var wbuf: [1024]u8 = undefined;
    var r = stream.reader(io, &rbuf);
    var w = stream.writer(io, &wbuf);

    while (true) {
        const n = r.interface.readSliceShort(&rbuf) catch {
            std.debug.print(
                "[Thread {d}] Read error, closing connection.\n",
                .{thread_num},
            );
            return;
        };
        if (n == 0) {
            std.debug.print("[Thread {d}] Client disconnected.\n", .{thread_num});
            break;
        }

        w.interface.writeAll(rbuf[0..n]) catch {
            std.debug.print(
                "[Thread {d}] Write error, closing connection.\n",
                .{thread_num},
            );
            return;
        };
        w.interface.flush() catch return;
    }
}
