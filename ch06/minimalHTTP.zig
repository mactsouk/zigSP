const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const address = try std.Io.net.IpAddress.parseIp4(
        "127.0.0.1",
        8080,
    );
    var server = try address.listen(io, .{});
    defer server.deinit(io);

    while (true) {
        const stream = try server.accept(io);
        handleConnection(io, stream) catch |err| {
            std.log.err("connection error: {}", .{err});
        };
    }
}

fn handleConnection(io: std.Io, stream: std.Io.net.Stream) !void {
    defer stream.close(io);
    var reader_buf: [1024]u8 = undefined;
    var writer_buf: [1024]u8 = undefined;
    var reader_impl = stream.reader(io, &reader_buf);
    var writer_impl = stream.writer(io, &writer_buf);
    var http_server = std.http.Server.init(
        &reader_impl.interface,
        &writer_impl.interface,
    );
    var req = try http_server.receiveHead();
    try req.respond("Hello world\n", .{});
}
