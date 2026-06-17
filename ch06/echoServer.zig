const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 2) {
        std.debug.print("Usage: echo_server <port>\n", .{});
        return error.MissingPort;
    }

    const port = try std.fmt.parseInt(u16, args[1], 10);
    const address = try std.Io.net.IpAddress.parseIp4("0.0.0.0", port);
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    std.debug.print("Listening on 0.0.0.0:{d}\n", .{port});

    while (true) {
        // A production server would catch transient errors (ECONNRESET,
        // EINTR) here and continue rather than propagating them to main().
        const stream = server.accept(io) catch |err| {
            std.log.err("accept: {}", .{err});
            continue;
        };
        defer stream.close(io);
        std.debug.print("Accepted connection\n", .{});

        var rbuf: [1024]u8 = undefined;
        var wbuf: [1024]u8 = undefined;
        var reader_impl = stream.reader(io, &rbuf);
        var writer_impl = stream.writer(io, &wbuf);
        const reader = &reader_impl.interface;
        const writer = &writer_impl.interface;

        while (true) {
            var buf: [1024]u8 = undefined;
            const n = reader.readSliceShort(&buf) catch break;
            if (n == 0) break;
            writer.writeAll(buf[0..n]) catch break;
            writer.flush() catch break;
        }
    }
}
