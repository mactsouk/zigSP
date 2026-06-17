const std = @import("std");
const Io = std.Io;

fn transferOneWay(io: Io, src: Io.net.Stream, dst: Io.net.Stream) void {
    var data: [4096]u8 = undefined;
    var wbuf: [4096]u8 = undefined;
    // Zero-length internal buffer: readVec reads directly into `data` without
    // spilling overflow bytes into a secondary buffer, giving true short reads.
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

// handleClient must return void because Io.Group.async requires
// it. All errors are therefore handled locally and logged
// rather than propagated.
fn handleClient(
    io: Io,
    client: Io.net.Stream,
    remote_addr: Io.net.IpAddress,
) void {
    defer client.close(io);

    const remote = remote_addr.connect(
        io,
        .{ .mode = .stream },
    ) catch |err| {
        std.debug.print(
            "[error] backend connect failed: {s}\n",
            .{@errorName(err)},
        );
        return;
    };
    defer remote.close(io);

    // Run both directions concurrently and wait for both to finish.
    var task_c2r = io.async(transferOneWay, .{ io, client, remote });
    defer task_c2r.cancel(io);
    var task_r2c = io.async(transferOneWay, .{ io, remote, client });
    defer task_r2c.cancel(io);

    task_c2r.await(io);
    task_r2c.await(io);

    std.debug.print("[session] closed\n", .{});
}

fn acceptLoop(io: Io, local_addr: Io.net.IpAddress, remote_addr: Io.net.IpAddress) !void {
    var server = try local_addr.listen(io, .{});
    defer server.deinit(io);

    var group: Io.Group = .init;
    defer group.cancel(io);

    while (true) {
        const client = server.accept(io) catch |err| {
            std.debug.print(
                "[accept error] {s}\n",
                .{@errorName(err)},
            );
            continue;
        };
        // Fire-and-forget the session handler
        group.async(
            io,
            handleClient,
            .{ io, client, remote_addr },
        );
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var iter = init.minimal.args.iterate();
    defer iter.deinit();
    _ = iter.next(); // skip program name

    var local_port: u16 = 8080;
    var remote_host: []const u8 = "127.0.0.1";
    var remote_port: u16 = 9000;

    if (iter.next()) |arg| local_port = std.fmt.parseInt(
        u16,
        arg,
        10,
    ) catch
        local_port;
    if (iter.next()) |arg| remote_host = arg;
    if (iter.next()) |arg| remote_port = std.fmt.parseInt(
        u16,
        arg,
        10,
    ) catch
        remote_port;

    std.debug.print(
        "zproxy: Listening on 0.0.0.0:{d} -> {s}:{d}\n",
        .{ local_port, remote_host, remote_port },
    );

    const local_addr = try Io.net.IpAddress.parseIp4(
        "0.0.0.0",
        local_port,
    );
    const remote_addr = try Io.net.IpAddress.resolve(
        io,
        remote_host,
        remote_port,
    );

    var acceptor = io.async(
        acceptLoop,
        .{ io, local_addr, remote_addr },
    );
    defer _ = acceptor.cancel(io) catch {};

    try acceptor.await(io);
}
