const std = @import("std");

const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("netinet/in.h");
    @cInclude("arpa/inet.h");
    @cInclude("unistd.h");
});

pub fn main(init: std.process.Init) !void {
    _ = init;
    const port: u16 = 1235;

    const sock_fd = c.socket(c.AF_INET, c.SOCK_DGRAM, 0);
    if (sock_fd < 0) return error.SocketCreateFailed;
    defer _ = c.close(sock_fd);

    var addr: c.sockaddr_in = .{
        .sin_family = c.AF_INET,
        .sin_port = std.mem.nativeToBig(u16, port),
        .sin_addr = .{ .s_addr = c.INADDR_ANY },
        .sin_zero = [_]u8{0} ** 8,
    };

    const sockaddr_ptr: *const c.sockaddr = @ptrCast(&addr);
    const sockaddr_len: c.socklen_t = @as(c.socklen_t, @sizeOf(c.sockaddr_in));

    if (c.bind(sock_fd, sockaddr_ptr, sockaddr_len) != 0)
        return error.BindFailed;

    std.debug.print("UDP server listening on port {d}\n", .{port});
    var buf: [1024]u8 = undefined;
    var client_addr: c.sockaddr_in = undefined;
    var addr_len: c.socklen_t = @as(c.socklen_t, @sizeOf(c.sockaddr_in));

    while (true) {
        const n = c.recvfrom(
            sock_fd,
            &buf,
            buf.len,
            0,
            @ptrCast(&client_addr),
            &addr_len,
        );
        if (n <= 0) continue;
        const msg_len: usize = @intCast(n);

        // Echo it back
        _ = c.sendto(
            sock_fd,
            &buf,
            msg_len,
            0,
            @ptrCast(&client_addr),
            addr_len,
        );

        const msg = buf[0..msg_len];
        std.debug.print("Received: {s}\n", .{msg});
    }
}
