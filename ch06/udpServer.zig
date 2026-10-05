const std = @import("std");
// Zig 0.16:
// const c = @cImport({
//     @cInclude("sys/socket.h");
//     @cInclude("netinet/in.h");
//     @cInclude("arpa/inet.h");
//     @cInclude("unistd.h");
// });
// Zig 0.17: zig translate-c -lc udpServer_c.h > udpServer_c.zig
const c = @import("udpServer_c.zig");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) {
        std.debug.print("Usage: {s} <port>\n", .{args[0]});
        return error.InvalidUsage;
    }

    const port = try std.fmt.parseInt(u16, args[1], 10);
    const sock = c.socket(c.AF_INET, c.SOCK_DGRAM, 0);
    if (sock < 0) return error.SocketCreateFailed;
    defer _ = c.close(sock);

    var addr: c.struct_sockaddr_in = std.mem.zeroInit(c.struct_sockaddr_in, .{
        .sin_family = @as(c.sa_family_t, @intCast(c.AF_INET)),
        .sin_port = std.mem.nativeToBig(u16, port),
        .sin_addr = .{ .s_addr = c.INADDR_ANY },
    });

    if (c.bind(
        sock,
        @ptrCast(&addr),
        @sizeOf(c.struct_sockaddr_in),
    ) < 0)
        return error.BindFailed;

    std.debug.print("Listening on 0.0.0.0:{}...\n", .{port});

    var buf: [1024]u8 = undefined;
    var other_addr: c.struct_sockaddr_in = undefined;
    var other_addrlen: c.socklen_t = @sizeOf(c.struct_sockaddr_in);

    while (true) {
        const n_recv = c.recvfrom(
            sock,
            &buf,
            buf.len,
            0,
            @ptrCast(&other_addr),
            &other_addrlen,
        );
        if (n_recv < 0) {
            std.debug.print("recvfrom failed\n", .{});
            continue;
        }
        std.debug.print("Received {d} byte(s)\n", .{n_recv});

        const n_sent = c.sendto(
            sock,
            &buf,
            @intCast(n_recv),
            0,
            @ptrCast(&other_addr),
            other_addrlen,
        );
        if (n_sent < 0) {
            std.debug.print("sendto failed\n", .{});
            continue;
        }
        std.debug.print("Sent {d} byte(s)\n", .{n_sent});
    }
}
