//! TCP echo server using io_uring (Linux only, kernel 5.6+).
//!
//! kqueue.zig in this chapter implements the same echo behaviour on macOS
//! using the BSD event queue.  This file is the Linux counterpart.
//!
//! io_uring is a shared-memory ring between userspace and the kernel,
//! introduced in Linux 5.1.  Instead of a syscall per I/O operation,
//! the application writes submission queue entries (SQEs) into the ring
//! and the kernel writes completion queue entries (CQEs) back.  A single
//! io_uring_enter(2) syscall can submit many operations and harvest many
//! completions at once, dramatically reducing kernel-crossing overhead for
//! high-throughput workloads.
//!
//! This server uses std.os.linux.IoUring, Zig's idiomatic wrapper.
//! The event loop encodes the operation type and client fd into each SQE's
//! user_data field so the completion handler knows what just finished.
//!
//! Compile: zig build-exe ch09/ioUring.zig   (Linux only; macOS → @compileError)
//! Run:     ./ioUring [port]           (default 9000)
//! Test:    nc localhost 9000          (type anything, see it echoed back)
//!
//! NOTE: On macOS the compiler emits an expected @compileError on line ~40
//! followed by a secondary type-mismatch inside std.os.linux.IoUring — both
//! are a consequence of Zig analysing Linux-specific stdlib code on macOS.
//! On Linux, the file compiles without errors.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const IoUring = linux.IoUring;
const posix = std.posix;

// Socket setup functions that posix.socket() used to cover; they were
// removed in Zig 0.16.  We call the C library directly instead.
const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("netinet/in.h");
    @cInclude("arpa/inet.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
});

comptime {
    if (builtin.os.tag != .linux)
        @compileError(
            "ioUring.zig is Linux-only (io_uring requires Linux 5.6+)",
        );
}

// -----------------------------------------------------------------
// user_data encoding.
//
// The 64-bit user_data field in each SQE is echoed verbatim in the
// matching CQE.  We pack the operation type into the high 32 bits and
// the file descriptor into the low 32 bits.
// -----------------------------------------------------------------
const Op = enum(u32) {
    accept = 0,
    recv = 1,
    send = 2,
};

fn mkUD(op: Op, fd: linux.fd_t) u64 {
    return (@as(u64, @intFromEnum(op)) << 32) |
        @as(u64, @as(u32, @bitCast(fd)));
}

fn udOp(ud: u64) Op {
    return @enumFromInt(@as(u32, @intCast(ud >> 32)));
}

fn udFd(ud: u64) linux.fd_t {
    return @bitCast(@as(u32, @truncate(ud)));
}

// -----------------------------------------------------------------
// Constants
// -----------------------------------------------------------------
const BACKLOG: c_int = 128;
const BUF_SIZE: usize = 4096;
const MAX_FD: usize = 1024;
const RING_SIZE: u16 = 256; // must be a power of two

// Per-client state.  Indexed by file descriptor value.
const Client = struct {
    recv_buf: [BUF_SIZE]u8 = undefined,
    // send_buf mirrors recv_buf; we reuse the same storage for echo.
    send_len: usize = 0,
};

// -----------------------------------------------------------------
// Main
// -----------------------------------------------------------------
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
    const listen_fd = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
    if (listen_fd < 0) return error.SocketFailed;
    defer _ = c.close(listen_fd);
    // Set non-blocking so accept() does not stall when io_uring races ahead.
    _ = c.fcntl(listen_fd, c.F_SETFL, c.O_NONBLOCK);

    var opt: c_int = 1;
    _ = c.setsockopt(
        listen_fd,
        c.SOL_SOCKET,
        c.SO_REUSEADDR,
        &opt,
        @sizeOf(c_int),
    );

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

    // ---- io_uring setup ------------------------------------------
    var ring = try IoUring.init(RING_SIZE, 0);
    defer ring.deinit();

    // Per-client state, heap-allocated (fds up to MAX_FD).
    const clients = try allocator.alloc(Client, MAX_FD);
    defer allocator.free(clients);

    var msgbuf: [256]u8 = undefined;
    try std.Io.File.stdout().writeStreamingAll(
        io,
        try std.fmt.bufPrint(
            &msgbuf,
            "io_uring echo server on :{d} (ring size {d})\n",
            .{ port, RING_SIZE },
        ),
    );

    // Queue the first accept before entering the loop.
    var peer_addr = std.mem.zeroes(posix.sockaddr);
    var peer_addrlen = @as(posix.socklen_t, @sizeOf(posix.sockaddr));
    _ = try ring.accept(
        mkUD(.accept, listen_fd),
        listen_fd,
        &peer_addr,
        &peer_addrlen,
        0,
    );
    _ = try ring.submit();

    // ---- Event loop ----------------------------------------------
    var cqes: [RING_SIZE]linux.io_uring_cqe = undefined;

    while (true) {
        // copy_cqes blocks until at least 1 CQE is available.
        const n = ring.copy_cqes(&cqes, 1) catch |err| {
            std.debug.print("copy_cqes error: {s}\n", .{@errorName(err)});
            continue;
        };

        for (cqes[0..n]) |*cqe| {
            const ud = cqe.user_data;

            switch (udOp(ud)) {
                // --------------------------------------------------
                .accept => {
                    // cqe.res is the new client fd (or a negative errno).
                    if (cqe.res < 0) {
                        // Transient error — re-queue the accept.
                    } else {
                        const client_fd = @as(linux.fd_t, @intCast(cqe.res));
                        const idx = @as(usize, @intCast(client_fd));

                        if (idx < MAX_FD) {
                            clients[idx] = .{};
                            // Queue a recv on the new connection.
                            _ = ring.recv(
                                mkUD(.recv, client_fd),
                                client_fd,
                                .{ .buffer = &clients[idx].recv_buf },
                                0,
                            ) catch {};
                            _ = ring.submit() catch {};

                            try std.Io.File.stdout().writeStreamingAll(
                                io,
                                try std.fmt.bufPrint(
                                    &msgbuf,
                                    "[+] fd={d}\n",
                                    .{client_fd},
                                ),
                            );
                        } else {
                            _ = c.close(client_fd);
                        }
                    }

                    // Always re-queue an accept so the next connection
                    // is picked up without an extra syscall round-trip.
                    _ = ring.accept(
                        mkUD(.accept, listen_fd),
                        listen_fd,
                        &peer_addr,
                        &peer_addrlen,
                        0,
                    ) catch {};
                    _ = ring.submit() catch {};
                },

                // --------------------------------------------------
                .recv => {
                    const fd = udFd(ud);
                    const idx = @as(usize, @intCast(fd));

                    if (cqe.res <= 0) {
                        // Peer closed or error — clean up.
                        _ = c.close(fd);
                        try std.Io.File.stdout().writeStreamingAll(
                            io,
                            try std.fmt.bufPrint(
                                &msgbuf,
                                "[-] fd={d} closed\n",
                                .{fd},
                            ),
                        );
                    } else {
                        // Echo the received bytes back.
                        const n_recv = @as(usize, @intCast(cqe.res));
                        clients[idx].send_len = n_recv;
                        _ = ring.send(
                            mkUD(.send, fd),
                            fd,
                            clients[idx].recv_buf[0..n_recv],
                            0,
                        ) catch {};
                        _ = ring.submit() catch {};
                    }
                },

                // --------------------------------------------------
                .send => {
                    const fd = udFd(ud);
                    const idx = @as(usize, @intCast(fd));

                    if (cqe.res > 0) {
                        // Send completed; queue the next recv.
                        clients[idx] = .{};
                        _ = ring.recv(
                            mkUD(.recv, fd),
                            fd,
                            .{ .buffer = &clients[idx].recv_buf },
                            0,
                        ) catch {};
                        _ = ring.submit() catch {};
                    } else {
                        _ = c.close(fd);
                    }
                },
            }
        }
    }
}
