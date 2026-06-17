const std = @import("std");
const Io = std.Io;
const Thread = std.Thread;

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = init.io;

    const argv = try init.minimal.args.toSlice(
        init.arena.allocator(),
    );

    if (argv.len != 4) {
        std.debug.print(
            "Usage: {s} <address> <port> <numConn>\n",
            .{argv[0]},
        );
        return;
    }

    const server_addr = argv[1];
    const server_port = try std.fmt.parseInt(u16, argv[2], 10);
    const num_connections = try std.fmt.parseInt(u32, argv[3], 10);

    const threads = try allocator.alloc(Thread, num_connections);
    defer allocator.free(threads);

    for (threads, 0..) |*t, i| {
        t.* = try Thread.spawn(
            .{ .allocator = allocator },
            connectAndEcho,
            .{ io, server_addr, server_port, @as(u32, @intCast(i)) },
        );
    }

    for (threads) |t| t.join();
}

fn connectAndEcho(io: Io, address_str: []const u8, port: u16, index: u32) void {
    const addr = Io.net.IpAddress.resolve(
        io,
        address_str,
        port,
    ) catch |err| {
        std.debug.print(
            "Client {d} resolve error: {}\n",
            .{ index, err },
        );
        return;
    };
    const stream = addr.connect(io, .{ .mode = .stream }) catch |err| {
        std.debug.print(
            "Client {d} connect error: {}\n",
            .{ index, err },
        );
        return;
    };
    defer stream.close(io);

    var msg_buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &msg_buf,
        "ping from client #{}\n",
        .{index},
    ) catch return;

    var wbuf: [256]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    w.interface.writeAll(msg) catch return;
    w.interface.flush() catch return;

    // Send TCP FIN so the server's readSliceShort returns instead of blocking.
    stream.shutdown(io, .send) catch return;

    var reader_buf: [1]u8 = undefined;
    var r = stream.reader(io, &reader_buf);
    var reply_buf: [64]u8 = undefined;
    const n = r.interface.readSliceShort(reply_buf[0..msg.len]) catch
        return;

    std.debug.print(
        "Client {d} received: {s}",
        .{ index, reply_buf[0..n] },
    );
}
