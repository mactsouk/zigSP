const std = @import("std");
const c = @cImport({
    @cInclude("netdb.h");
    @cInclude("sys/socket.h");
    @cInclude("arpa/inet.h");
    @cInclude("netinet/in.h");
});

pub fn main(init: std.process.Init) !void {
    var iter = init.minimal.args.iterate();
    defer iter.deinit();
    _ = iter.next();

    const hostname = iter.next() orelse {
        std.debug.print("Usage: resolveHostname <hostname>\n", .{});
        return;
    };

    var hints: c.addrinfo = .{};
    hints.ai_family = c.AF_UNSPEC; // Accept both IPv4 and IPv6
    hints.ai_socktype = c.SOCK_STREAM; // TCP stream sockets
    hints.ai_flags = 0;

    var res: ?*c.addrinfo = null;

    const err = c.getaddrinfo(hostname, null, &hints, &res);
    if (err != 0) {
        const errStr = c.gai_strerror(err);
        std.debug.print("getaddrinfo error: {s}\n", .{errStr});
        return;
    }
    defer c.freeaddrinfo(res);

    var ai = res;
    while (ai != null) : (ai = ai.?.ai_next) {
        const family = ai.?.ai_family;

        if (family == c.AF_INET) {
            const sockaddr4: *const c.sockaddr_in =
                @ptrCast(@alignCast(ai.?.ai_addr));
            var ipBuf: [16]u8 = undefined;

            const ip_ptr: *const u8 = @ptrCast(&sockaddr4.sin_addr);
            const ip_cstr = c.inet_ntop(
                family,
                ip_ptr,
                &ipBuf,
                ipBuf.len,
            );

            if (ip_cstr == null) {
                std.debug.print(
                    "inet_ntop failed for IPv4 address.\n",
                    .{},
                );
                continue;
            }

            const ipStr = std.mem.sliceTo(ipBuf[0..], 0);
            std.debug.print("IPv4: {s}\n", .{ipStr});
        } else if (family == c.AF_INET6) {
            const sockaddr6: *const c.sockaddr_in6 =
                @ptrCast(@alignCast(ai.?.ai_addr));
            var ipBuf: [46]u8 = undefined;

            const ip_ptr: *const u8 = @ptrCast(&sockaddr6.sin6_addr);
            const ip_cstr = c.inet_ntop(
                family,
                ip_ptr,
                &ipBuf,
                ipBuf.len,
            );
            if (ip_cstr == null) {
                std.debug.print(
                    "inet_ntop failed for IPv6 address.\n",
                    .{},
                );
                continue;
            }

            const ipStr = std.mem.sliceTo(ipBuf[0..], 0);
            std.debug.print("IPv6: {s}\n", .{ipStr});
        }
    }
}
