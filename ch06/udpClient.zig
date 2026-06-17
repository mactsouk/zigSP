const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var err_buf: [1024]u8 = undefined;
    var stderr_impl = std.Io.File.stderr().writer(io, &err_buf);
    const stderr = &stderr_impl.interface;
    var out_buf: [1024]u8 = undefined;
    var stdout_impl = std.Io.File.stdout().writer(io, &out_buf);
    const stdout = &stdout_impl.interface;

    if (args.len != 4) {
        try stderr.print(
            "Usage: {s} <hostname> <port> <message>\n",
            .{args[0]},
        );
        try stderr.flush();
        std.process.exit(1);
    }

    const hostname = args[1];
    const port_str = args[2];
    const message = args[3];
    const port = try std.fmt.parseInt(u16, port_str, 10);

    // Resolve hostname to an IP address using pure Zig
    const hn = try std.Io.net.HostName.init(hostname);
    var lookup_buf: [16]std.Io.net.HostName.LookupResult = undefined;
    var lookup_queue: std.Io.Queue(
        std.Io.net.HostName.LookupResult,
    ) = .init(&lookup_buf);
    try hn.lookup(io, &lookup_queue, .{ .port = port });

    var dest_addr: ?std.Io.net.IpAddress = null;
    while (lookup_queue.getOne(io)) |result| {
        switch (result) {
            .address => |addr| if (dest_addr == null) {
                dest_addr = addr;
            },
            .canonical_name => {},
        }
    } else |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.Closed => {},
    }
    const dest = dest_addr orelse return error.UnknownHostName;

    // Bind a local UDP socket (port 0 lets the OS pick an ephemeral port)
    const local = try std.Io.net.IpAddress.parseIp4("0.0.0.0", 0);
    const sock = try local.bind(io, .{ .mode = .dgram });
    defer sock.close(io);

    // Send the datagram
    try sock.send(io, &dest, message);
    try stdout.print(
        "Sent {d} bytes to {s}:{d}: {s}\n",
        .{ message.len, hostname, port, message },
    );
    try stdout.flush();

    // Receive the response.
    // Note: sock.receive() blocks indefinitely if the server
    // does not reply. In a real application you would set a receive
    // timeout (e.g. SO_RCVTIMEO) to handle packet loss or an
    // unresponsive server gracefully.
    var buffer: [1024]u8 = undefined;
    const incoming = try sock.receive(io, &buffer);
    try stdout.print(
        "Received {d} bytes: {s}\n",
        .{ incoming.data.len, incoming.data },
    );
    try stdout.flush();
}
