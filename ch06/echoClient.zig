const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var iter = init.minimal.args.iterate();
    defer iter.deinit();
    _ = iter.next();

    const host = iter.next() orelse {
        std.debug.print("Usage: echoClient <host> <port>\n", .{});
        return error.MissingHost;
    };
    const port_str = iter.next() orelse {
        std.debug.print("Usage: echoClient <host> <port>\n", .{});
        return error.MissingPort;
    };

    const port = try std.fmt.parseInt(u16, port_str, 10);
    const address = try std.Io.net.IpAddress.parseIp4(host, port);
    const stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    const message = "Hello from Zig client!\n";
    var rbuf: [1024]u8 = undefined;
    var wbuf: [1024]u8 = undefined;
    var reader_impl = stream.reader(io, &rbuf);
    var writer_impl = stream.writer(io, &wbuf);
    const reader = &reader_impl.interface;
    const writer = &writer_impl.interface;

    try writer.writeAll(message);
    try writer.flush();
    try stream.shutdown(io, .send);

    const n = reader.readSliceShort(&rbuf) catch 0;
    if (n == 0) {
        std.debug.print("Server closed connection.\n", .{});
        return;
    }

    const response = rbuf[0..n];
    var out_buf: [1024]u8 = undefined;
    var stdout_impl = std.Io.File.stdout().writer(io, &out_buf);
    const stdout = &stdout_impl.interface;
    try stdout.print("Received: {s}", .{response});
    try stdout.flush();
}
