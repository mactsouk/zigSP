// proxyBench.zig — benchmark utility for tcpProxy.zig and proxyAsync.zig
//
// Two modes:
//   --server PORT [--latency N]   run a TCP echo server (use as the proxy backend)
//   --bench  HOST PORT            fire N concurrent connections through the proxy
//
// Use --latency N (milliseconds) to inject artificial backend delay so the
// difference between serial (tcpProxy) and concurrent (proxyAsync) is visible:
//   $ zig run proxyBench.zig -- --server 9000 --latency 50
//   $ zig run tcpProxy.zig   -- 8080 127.0.0.1 9000   (or proxyAsync.zig)
//   $ zig run proxyBench.zig -- --bench 127.0.0.1 8080 --conns 10 --bytes 4096
//
// Protocol: each connection sends a 4-byte big-endian payload length followed
// by that many bytes; the echo server reads the length, reads the payload, and
// writes the payload back.  No half-close needed.

const std = @import("std");
const Io = std.Io;

// ---------------------------------------------------------------------------
// Shared benchmark counters (written from concurrent tasks)
// ---------------------------------------------------------------------------
const Results = struct {
    done: std.atomic.Value(u64) = .init(0),
    failed: std.atomic.Value(u64) = .init(0),
    bytes: std.atomic.Value(u64) = .init(0),
    latency_ns: std.atomic.Value(u64) = .init(0),
};

// ---------------------------------------------------------------------------
// Echo server
// ---------------------------------------------------------------------------

// Reads a 4-byte big-endian length N, reads N payload bytes, writes them back.
// latency_ms: optional artificial delay before responding, to make serialisation
// costs visible when comparing tcpProxy (serial) against proxyAsync (concurrent).
fn echoSession(io: Io, client: Io.net.Stream, latency_ms: i64) void {
    defer client.close(io);

    var rbuf: [4096]u8 = undefined;
    var wbuf: [4096]u8 = undefined;
    var r = client.reader(io, &rbuf);
    var w = client.writer(io, &wbuf);

    var hdr: [4]u8 = undefined;
    r.interface.readSliceAll(&hdr) catch return;
    const n = std.mem.readInt(u32, &hdr, .big);
    if (n == 0 or n > 1024 * 1024) return; // sanity guard (1 MB max)

    const buf = std.heap.page_allocator.alloc(u8, n) catch return;
    defer std.heap.page_allocator.free(buf);

    r.interface.readSliceAll(buf) catch return;

    if (latency_ms > 0)
        io.sleep(Io.Duration.fromMilliseconds(latency_ms), .awake) catch {};

    w.interface.writeAll(buf) catch return;
    w.interface.flush() catch {};
}

fn runEchoServer(io: Io, port: u16, latency_ms: i64) !void {
    const addr = try Io.net.IpAddress.parseIp4("127.0.0.1", port);
    var server = try addr.listen(io, .{});
    defer server.deinit(io);
    std.debug.print("Echo server ready on 127.0.0.1:{d} (latency {d}ms)\n", .{ port, latency_ms });

    var group: Io.Group = .init;
    defer group.cancel(io);
    while (true) {
        const client = try server.accept(io);
        group.async(io, echoSession, .{ io, client, latency_ms });
    }
}

// ---------------------------------------------------------------------------
// Benchmark client
// ---------------------------------------------------------------------------

// One connection: send length-prefixed payload, read payload back.
fn benchConn(io: Io, proxy_addr: Io.net.IpAddress, payload: []const u8, results: *Results) void {
    const t0 = std.Io.Timestamp.now(io, .awake);

    const conn = proxy_addr.connect(io, .{ .mode = .stream }) catch {
        _ = results.failed.fetchAdd(1, .monotonic);
        return;
    };
    defer conn.close(io);

    const readback = std.heap.page_allocator.alloc(u8, payload.len) catch {
        _ = results.failed.fetchAdd(1, .monotonic);
        return;
    };
    defer std.heap.page_allocator.free(readback);

    var wbuf: [4096]u8 = undefined;
    var rbuf: [4096]u8 = undefined;
    var w = conn.writer(io, &wbuf);
    var r = conn.reader(io, &rbuf);

    // Send: 4-byte big-endian length prefix + payload
    var hdr: [4]u8 = undefined;
    std.mem.writeInt(u32, &hdr, @intCast(payload.len), .big);
    w.interface.writeAll(&hdr) catch {
        _ = results.failed.fetchAdd(1, .monotonic);
        return;
    };
    w.interface.writeAll(payload) catch {
        _ = results.failed.fetchAdd(1, .monotonic);
        return;
    };
    w.interface.flush() catch {
        _ = results.failed.fetchAdd(1, .monotonic);
        return;
    };

    // Receive echoed payload
    r.interface.readSliceAll(readback) catch {
        _ = results.failed.fetchAdd(1, .monotonic);
        return;
    };

    const t1 = std.Io.Timestamp.now(io, .awake);
    const lat: u64 = @intCast(t1.nanoseconds - t0.nanoseconds);
    _ = results.latency_ns.fetchAdd(lat, .monotonic);
    _ = results.done.fetchAdd(1, .monotonic);
    _ = results.bytes.fetchAdd(payload.len, .monotonic);
}

fn runBench(
    io: Io,
    host: []const u8,
    port: u16,
    num_conns: u32,
    payload_size: u32,
    allocator: std.mem.Allocator,
) !void {
    const proxy_addr = try Io.net.IpAddress.resolve(io, host, port);

    const payload = try allocator.alloc(u8, payload_size);
    defer allocator.free(payload);
    @memset(payload, 'X');

    std.debug.print(
        "Benchmarking {s}:{d}  —  {d} concurrent connections × {d} bytes\n",
        .{ host, port, num_conns, payload_size },
    );

    var results: Results = .{};
    const t_start = std.Io.Timestamp.now(io, .awake);

    // Spawn all connections concurrently, then wait for all to complete.
    var group: Io.Group = .init;
    defer group.cancel(io);
    for (0..num_conns) |_| {
        group.async(io, benchConn, .{ io, proxy_addr, payload, &results });
    }
    try group.await(io);

    const t_end = std.Io.Timestamp.now(io, .awake);

    const done = results.done.load(.monotonic);
    const failed = results.failed.load(.monotonic);
    const total_bytes = results.bytes.load(.monotonic);
    const total_lat_ns = results.latency_ns.load(.monotonic);
    const elapsed_ns: u64 = @intCast(t_end.nanoseconds - t_start.nanoseconds);
    const elapsed_ms: u64 = elapsed_ns / 1_000_000;

    const throughput_mbs: f64 = if (elapsed_ns > 0)
        @as(f64, @floatFromInt(total_bytes)) /
            (@as(f64, @floatFromInt(elapsed_ns)) / 1e9) /
            (1024.0 * 1024.0)
    else
        0.0;

    const avg_lat_ms: f64 = if (done > 0)
        @as(f64, @floatFromInt(total_lat_ns / done)) / 1_000_000.0
    else
        0.0;

    std.debug.print("\n=== Benchmark Results ===\n", .{});
    std.debug.print("Connections:      {d} ok  /  {d} failed\n", .{ done, failed });
    std.debug.print("Total bytes:      {d}\n", .{total_bytes});
    std.debug.print("Wall-clock time:  {d} ms\n", .{elapsed_ms});
    std.debug.print("Throughput:       {d:.2} MB/s\n", .{throughput_mbs});
    std.debug.print("Avg conn latency: {d:.2} ms\n", .{avg_lat_ms});
    std.debug.print("\n", .{});
    std.debug.print(
        "NOTE: wall-clock time scales with --conns on tcpProxy (serial),\n" ++
            "      but stays roughly constant on proxyAsync (concurrent).\n",
        .{},
    );
}

// ---------------------------------------------------------------------------
// Usage
// ---------------------------------------------------------------------------
fn printUsage() void {
    std.debug.print(
        \\Usage:
        \\  proxyBench --server PORT [--latency N]
        \\      Start a TCP echo server on 127.0.0.1:PORT
        \\      --latency N   sleep N milliseconds before each response (default: 0)
        \\
        \\  proxyBench --bench HOST PORT [--conns N] [--bytes B]
        \\      Benchmark a proxy at HOST:PORT
        \\      --conns N   concurrent connections (default: 50)
        \\      --bytes B   payload bytes per connection (default: 4096)
        \\
        \\Workflow (with artificial latency to show serial vs concurrent difference):
        \\  terminal 1: zig run proxyBench.zig -- --server 9000 --latency 50
        \\  terminal 2: zig run tcpProxy.zig   -- 8080 127.0.0.1 9000
        \\  terminal 3: zig run proxyBench.zig -- --bench 127.0.0.1 8080 --conns 10 --bytes 4096
        \\  (repeat terminal 2/3 swapping in proxyAsync.zig to compare)
        \\
    , .{});
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------
pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var iter = init.minimal.args.iterate();
    defer iter.deinit();
    _ = iter.next(); // skip program name

    const cmd = iter.next() orelse {
        printUsage();
        return;
    };

    if (std.mem.eql(u8, cmd, "--server")) {
        const port_str = iter.next() orelse {
            printUsage();
            return;
        };
        const port = try std.fmt.parseInt(u16, port_str, 10);
        var latency_ms: i64 = 0;
        while (iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "--latency")) {
                if (iter.next()) |v| latency_ms = try std.fmt.parseInt(i64, v, 10);
            }
        }
        try runEchoServer(io, port, latency_ms);
        //
    } else if (std.mem.eql(u8, cmd, "--bench")) {
        const host = iter.next() orelse {
            printUsage();
            return;
        };
        const port_str = iter.next() orelse {
            printUsage();
            return;
        };
        const port = try std.fmt.parseInt(u16, port_str, 10);

        var num_conns: u32 = 50;
        var payload_size: u32 = 4096;
        while (iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "--conns")) {
                if (iter.next()) |v| num_conns = try std.fmt.parseInt(u32, v, 10);
            } else if (std.mem.eql(u8, arg, "--bytes")) {
                if (iter.next()) |v| payload_size = try std.fmt.parseInt(u32, v, 10);
            }
        }

        try runBench(io, host, port, num_conns, payload_size, init.gpa);
        //
    } else {
        printUsage();
    }
}
