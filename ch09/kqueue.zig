//! TCP echo server using kqueue (macOS / BSD).
//!
//! This program implements a raw echo server directly against the kqueue
//! kernel interface so the event-loop machinery is visible.  Note that
//! std.Io on macOS is backed by Grand Central Dispatch (GCD), not kqueue
//! directly — kqueue.zig is a standalone low-level example, not a reflection
//! of what std.Io does internally.
//!
//! kqueue is the BSD event notification facility.  A single kernel fd (the
//! "kqueue") accumulates events from any number of watched sources: sockets,
//! files, processes, timers.  You tell the kernel what to watch via kevent(2)
//! with EV_ADD, then block in kevent(2) waiting for notifications.  Unlike
//! select/poll, there is no O(n) scan — the kernel delivers only the fds
//! that are actually ready.
//!
//! Compile: zig build-exe ch09/kqueue.zig
//! Run:     ./kqueue [port]           (default 9000)
//! Test:    nc localhost 9000         (type anything, see it echoed back)

const std = @import("std");
const builtin = @import("builtin");
// Zig 0.16:
// const c = @cImport({
//     @cInclude("sys/event.h");
//     @cInclude("sys/socket.h");
//     @cInclude("netinet/in.h");
//     @cInclude("arpa/inet.h");
//     @cInclude("unistd.h");
//     @cInclude("fcntl.h");
// });
// Zig 0.17: zig translate-c -lc kqueue_c.h > kqueue_c.zig
const c = @import("kqueue_c.zig");

comptime {
    if (builtin.os.tag != .macos and !builtin.os.tag.isBSD())
        @compileError("kqueue.zig requires macOS or a BSD system");
}

const MAX_EVENTS: usize = 64;
const BACKLOG: c_int = 128;
const BUF_SIZE: usize = 4096;
// Maximum tracked fd value.  Fds above this are closed immediately.
const MAX_FD: usize = 1024;

// Per-connection read buffer.  Indexed by file descriptor.
const Conn = struct {
    buf: [BUF_SIZE]u8 = undefined,
};

fn setNonBlocking(fd: c_int) !void {
    const flags = c.fcntl(fd, c.F_GETFL, @as(c_int, 0));
    if (flags == -1) return error.FcntlFailed;
    if (c.fcntl(fd, c.F_SETFL, flags | c.O_NONBLOCK) == -1)
        return error.FcntlFailed;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    var iter = init.minimal.args.iterate();
    defer iter.deinit();
    _ = iter.next();

    var port: u16 = 9000;
    if (iter.next()) |arg|
        port = std.fmt.parseInt(u16, arg, 10) catch port;

    // ---- Listening socket ----------------------------------------
    // std.posix.socket() was removed in 0.16; use C FFI directly.
    const listen_fd = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
    if (listen_fd < 0) return error.SocketFailed;
    defer _ = c.close(listen_fd);

    var opt: c_int = 1;
    _ = c.setsockopt(
        listen_fd,
        c.SOL_SOCKET,
        c.SO_REUSEADDR,
        &opt,
        @sizeOf(c_int),
    );
    try setNonBlocking(listen_fd);

    var addr = std.mem.zeroes(c.struct_sockaddr_in);
    addr.sin_family = c.AF_INET;
    addr.sin_port = c.htons(port);
    addr.sin_addr.s_addr = c.htonl(c.INADDR_ANY);

    if (c.bind(
        listen_fd,
        @ptrCast(&addr),
        @sizeOf(c.struct_sockaddr_in),
    ) != 0)
        return error.BindFailed;
    if (c.listen(listen_fd, BACKLOG) != 0)
        return error.ListenFailed;

    // ---- kqueue setup --------------------------------------------
    const kq = std.c.kqueue();
    if (kq < 0) return error.KqueueFailed;
    defer _ = std.c.close(kq);

    // Register the listen socket: notify when a connection is ready to accept.
    const listen_ev = c.struct_kevent{
        .ident = @intCast(listen_fd),
        .filter = c.EVFILT_READ,
        .flags = c.EV_ADD,
        .fflags = 0,
        .data = 0,
        .udata = null,
    };
    _ = c.kevent(kq, &listen_ev, 1, null, 0, null);

    // Per-connection buffers heap-allocated to keep the stack small.
    const conns = try allocator.alloc(Conn, MAX_FD);
    defer allocator.free(conns);

    var msgbuf: [256]u8 = undefined;
    try std.Io.File.stdout().writeStreamingAll(
        io,
        try std.fmt.bufPrint(
            &msgbuf,
            "kqueue echo server on :{d}\n",
            .{port},
        ),
    );

    // ---- Event loop ----------------------------------------------
    var events: [MAX_EVENTS]c.struct_kevent = undefined;

    while (true) {
        // Block until at least one event is ready (timeout = null → infinite).
        const n = c.kevent(kq, null, 0, &events, MAX_EVENTS, null);
        if (n < 0) continue;

        for (0..@intCast(n)) |i| {
            const ev = &events[i];
            const fd = @as(c_int, @intCast(ev.ident));

            if (fd == listen_fd) {
                // ---- Accept new connection -----------------------
                var client_addr = std.mem.zeroes(c.struct_sockaddr_in);
                var addr_len: c.socklen_t = @sizeOf(c.struct_sockaddr_in);
                const client_fd = c.accept(
                    listen_fd,
                    @ptrCast(&client_addr),
                    &addr_len,
                );
                if (client_fd < 0) continue;

                if (@as(usize, @intCast(client_fd)) >= MAX_FD) {
                    _ = c.close(client_fd);
                    continue;
                }

                try setNonBlocking(client_fd);

                // Register client fd for read events.
                const client_ev = c.struct_kevent{
                    .ident = @intCast(client_fd),
                    .filter = c.EVFILT_READ,
                    .flags = c.EV_ADD,
                    .fflags = 0,
                    .data = 0,
                    .udata = null,
                };
                _ = c.kevent(kq, &client_ev, 1, null, 0, null);

                const ip = c.inet_ntoa(client_addr.sin_addr);
                try std.Io.File.stdout().writeStreamingAll(
                    io,
                    try std.fmt.bufPrint(
                        &msgbuf,
                        "[+] fd={d} from {s}\n",
                        .{ client_fd, std.mem.span(ip) },
                    ),
                );
            } else {
                // ---- Client I/O ----------------------------------
                // EV_EOF is set when the remote peer has closed its end.
                const eof = (ev.flags & c.EV_EOF) != 0;
                if (eof) {
                    _ = c.close(fd);
                    try std.Io.File.stdout().writeStreamingAll(
                        io,
                        try std.fmt.bufPrint(
                            &msgbuf,
                            "[-] fd={d} closed\n",
                            .{fd},
                        ),
                    );
                    continue;
                }

                // Read however many bytes are available (non-blocking).
                const idx = @as(usize, @intCast(fd));
                const nr = c.read(fd, &conns[idx].buf, BUF_SIZE);
                if (nr <= 0) {
                    _ = c.close(fd);
                    continue;
                }

                // Echo back — write is non-blocking too; for a real server
                // you would queue unsent bytes and watch EVFILT_WRITE.
                _ = c.write(fd, &conns[idx].buf, @intCast(nr));
            }
        }
    }
}
