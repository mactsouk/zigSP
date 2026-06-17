const std = @import("std");
const Io = std.Io;

fn transferOneWay(io: Io, src: Io.net.Stream, dst: Io.net.Stream) void {
    var data: [4096]u8 = undefined;
    var wbuf: [4096]u8 = undefined;
    // Zero-length internal buffer: readVec reads directly into
    // `data` without spilling overflow bytes into a secondary
    // buffer, giving true short reads.
    var r = src.reader(io, &[0]u8{});
    var w = dst.writer(io, &wbuf);
    var bufs: [1][]u8 = .{&data};
    while (true) {
        const n = r.interface.readVec(&bufs) catch break;
        if (n == 0) break;
        w.interface.writeAll(data[0..n]) catch break;
        w.interface.flush() catch break;
    }
    // Half-close so the peer knows the request is complete.
    // Production code should log errors via @errorName(err).
    dst.shutdown(io, .send) catch {};
}

// handleSession blocks until both directions complete.
fn handleSession(
    io: Io,
    client: Io.net.Stream,
    remote_addr: Io.net.IpAddress,
) !void {
    defer client.close(io);

    const remote = try remote_addr.connect(io, .{ .mode = .stream });
    defer remote.close(io);

    // Run both directions concurrently and wait for both to finish.
    var task_c2r = io.async(transferOneWay, .{ io, client, remote });
    defer task_c2r.cancel(io);
    var task_r2c = io.async(transferOneWay, .{ io, remote, client });
    defer task_r2c.cancel(io);

    task_c2r.await(io);
    task_r2c.await(io);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    // Parse Command Line Arguments
    var iter = init.minimal.args.iterate();
    defer iter.deinit();
    _ = iter.next(); // skip program name

    // Defaults
    var local_port: u16 = 8080;
    var remote_host: []const u8 = "127.0.0.1";
    var remote_port: u16 = 9000;

    const arg1 = iter.next();
    const arg2 = iter.next();
    const arg3 = iter.next();

    if (arg1) |arg| {
        local_port = std.fmt.parseInt(u16, arg, 10) catch |err| {
            std.debug.print("Invalid local port: {s}\n", .{arg});
            return err;
        };
    }

    if (arg2) |arg| {
        remote_host = arg;
    }

    if (arg3) |arg| {
        remote_port = std.fmt.parseInt(u16, arg, 10) catch |err| {
            std.debug.print("Invalid remote port: {s}\n", .{arg});
            return err;
        };
    }

    if (arg1 == null) {
        std.debug.print("Using default ports.\n", .{});
        std.debug.print(
            "To change: zproxy <local_port> <remote_host> <remote_port>\n",
            .{},
        );
        std.debug.print("Example:   zproxy 3000 127.0.0.1 5000\n\n", .{});
    }

    std.debug.print(
        "zproxy: Listening on 0.0.0.0:{d} -> {s}:{d}\n",
        .{ local_port, remote_host, remote_port },
    );

    // Resolve addresses
    const local_addr = try Io.net.IpAddress.parseIp4("0.0.0.0", local_port);
    const remote_addr = try Io.net.IpAddress.resolve(io, remote_host, remote_port);

    // Setup Listener
    var server = try local_addr.listen(io, .{});
    defer server.deinit(io);

    // Event Loop: handle one connection at a time
    // (see proxyAsync.zig for a concurrent multi-connection version)
    while (true) {
        const client = try server.accept(io);
        std.debug.print("[New Connection]\n", .{});
        handleSession(io, client, remote_addr) catch |err| {
            std.debug.print("[Session error] {s}\n", .{@errorName(err)});
        };
        std.debug.print("[Session closed]\n", .{});
    }
}
