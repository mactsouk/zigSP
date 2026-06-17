const std = @import("std");
const c = @cImport({
    @cInclude("signal.h");
    @cInclude("unistd.h");
});

export fn handle_sigint(sig: c_int) callconv(.c) void {
    _ = sig;
    std.debug.print("Caught SIGINT! Shutting down server...\n", .{});
    std.process.exit(0);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    _ = c.signal(c.SIGINT, handle_sigint);

    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 8080);
    var server = try address.listen(io, .{});
    defer server.deinit(io);

    std.debug.print("Server listening on http://127.0.0.1:8080\n", .{});
    std.debug.print("Press Ctrl+C to stop the server\n", .{});

    while (true) {
        const stream = try server.accept(io);
        try handleConnection(io, stream, allocator);
    }
}

fn handleConnection(
    io: std.Io,
    stream: std.Io.net.Stream,
    allocator: std.mem.Allocator,
) !void {
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

    const path = req.head.target;

    if (std.mem.eql(u8, path, "/")) {
        try req.respond(
            "Welcome to the Zig Web Server!\n",
            .{
                .status = .ok,
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "text/plain" },
                },
            },
        );
    } else if (std.mem.eql(u8, path, "/rand")) {
        var rand_bytes: [4]u8 = undefined;
        io.random(&rand_bytes);
        const random_num = std.mem.readInt(u32, &rand_bytes, .little) % 1_000_001;
        const body = try std.fmt.allocPrint(
            allocator,
            "Random number: {}\n",
            .{random_num},
        );
        defer allocator.free(body);
        try req.respond(body, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/plain" },
            },
        });
    } else {
        try req.respond("404 Not Found\n", .{
            .status = .not_found,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/plain" },
            },
        });
    }
}
