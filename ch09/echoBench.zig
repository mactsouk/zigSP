//! echoBench.zig — benchmark raw-echo servers (ioUring.zig / kqueue.zig).
//!
//! Both echo servers speak raw bytes: whatever arrives on the socket is sent
//! straight back.  This tool fires N concurrent connections, sends a fixed
//! payload on each, reads it back, and reports throughput and latency.
//!
//! Usage:
//!   zig run ch09/echoBench.zig -- HOST PORT [--conns N] [--bytes B] [--rounds R]
//!
//! Workflow (two terminals):
//!   terminal 1 (macOS):  zig run ch09/kqueue.zig  -- 9000
//!   terminal 1 (Linux):  zig run ch09/ioUring.zig -- 9000
//!   terminal 2:          zig run ch09/echoBench.zig -- 127.0.0.1 9000
//!   terminal 2 (tuned):  zig run ch09/echoBench.zig -- 127.0.0.1 9000 --conns 200 --bytes 8192 --rounds 5

const std = @import("std");
const Io  = std.Io;

// ---------------------------------------------------------------------------
// Shared benchmark counters — written from concurrent tasks.
// ---------------------------------------------------------------------------
const Results = struct {
    done:       std.atomic.Value(u64) = .init(0),
    failed:     std.atomic.Value(u64) = .init(0),
    bytes:      std.atomic.Value(u64) = .init(0),
    latency_ns: std.atomic.Value(u64) = .init(0),
};

// ---------------------------------------------------------------------------
// One benchmark connection: connect → send payload → recv payload → done.
// ---------------------------------------------------------------------------
fn benchConn(
    io:         Io,
    addr:       Io.net.IpAddress,
    payload:    []const u8,
    results:    *Results,
) void {
    const t0 = std.Io.Timestamp.now(io, .awake);

    const conn = addr.connect(io, .{ .mode = .stream }) catch {
        _ = results.failed.fetchAdd(1, .monotonic);
        return;
    };
    defer conn.close(io);

    var wbuf: [4096]u8 = undefined;
    var rbuf: [4096]u8 = undefined;
    var w = conn.writer(io, &wbuf);
    var r = conn.reader(io, &rbuf);

    // Send the whole payload.
    w.interface.writeAll(payload) catch {
        _ = results.failed.fetchAdd(1, .monotonic);
        return;
    };
    w.interface.flush() catch {
        _ = results.failed.fetchAdd(1, .monotonic);
        return;
    };

    // Read back the same number of bytes.
    const readback = std.heap.page_allocator.alloc(u8, payload.len) catch {
        _ = results.failed.fetchAdd(1, .monotonic);
        return;
    };
    defer std.heap.page_allocator.free(readback);

    r.interface.readSliceAll(readback) catch {
        _ = results.failed.fetchAdd(1, .monotonic);
        return;
    };

    const t1 = std.Io.Timestamp.now(io, .awake);
    _ = results.done.fetchAdd(1, .monotonic);
    _ = results.bytes.fetchAdd(payload.len, .monotonic);
    _ = results.latency_ns.fetchAdd(
        @as(u64, @intCast(t1.nanoseconds - t0.nanoseconds)),
        .monotonic,
    );
}

// ---------------------------------------------------------------------------
// Run one round: spawn num_conns concurrent connections, wait, print stats.
// ---------------------------------------------------------------------------
fn runRound(
    io:          Io,
    addr:        Io.net.IpAddress,
    num_conns:   u32,
    payload:     []const u8,
    round:       u32,
) !void {
    var results: Results = .{};
    const t_start = std.Io.Timestamp.now(io, .awake);

    var group: Io.Group = .init;
    defer group.cancel(io);
    for (0..num_conns) |_|
        group.async(io, benchConn, .{ io, addr, payload, &results });
    try group.await(io);

    const t_end = std.Io.Timestamp.now(io, .awake);

    const done    = results.done.load(.monotonic);
    const failed  = results.failed.load(.monotonic);
    const tot_b   = results.bytes.load(.monotonic);
    const tot_lat = results.latency_ns.load(.monotonic);
    const elapsed_ns: u64 = @intCast(t_end.nanoseconds - t_start.nanoseconds);

    const throughput_mbs: f64 = if (elapsed_ns > 0)
        @as(f64, @floatFromInt(tot_b)) /
            (@as(f64, @floatFromInt(elapsed_ns)) / 1e9) / (1024.0 * 1024.0)
    else
        0.0;

    const avg_lat_ms: f64 = if (done > 0)
        @as(f64, @floatFromInt(tot_lat / done)) / 1_000_000.0
    else
        0.0;

    std.debug.print(
        "Round {d}:  {d} ok  {d} failed  |  {d:.2} MB/s  |  avg latency {d:.2} ms  |  wall {d} ms\n",
        .{
            round,
            done,
            failed,
            throughput_mbs,
            avg_lat_ms,
            elapsed_ns / 1_000_000,
        },
    );
}

// ---------------------------------------------------------------------------
// Usage
// ---------------------------------------------------------------------------
fn printUsage() void {
    std.debug.print(
        \\Usage:
        \\  echoBench HOST PORT [--conns N] [--bytes B] [--rounds R]
        \\
        \\  HOST          server address (e.g. 127.0.0.1)
        \\  PORT          server port    (e.g. 9000)
        \\  --conns N     concurrent connections per round  (default: 50)
        \\  --bytes B     payload bytes per connection      (default: 4096)
        \\  --rounds R    number of measurement rounds      (default: 3)
        \\
        \\Workflow:
        \\  macOS: zig run ch09/kqueue.zig  -- 9000
        \\  Linux: zig run ch09/ioUring.zig -- 9000
        \\  bench: zig run ch09/echoBench.zig -- 127.0.0.1 9000 --conns 100 --bytes 8192
        \\
    , .{});
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------
pub fn main(init: std.process.Init) !void {
    const io        = init.io;
    const allocator = init.gpa;

    var iter = init.minimal.args.iterate();
    defer iter.deinit();
    _ = iter.next(); // skip program name

    const host_arg = iter.next() orelse { printUsage(); return; };
    const port_arg = iter.next() orelse { printUsage(); return; };
    const port = std.fmt.parseInt(u16, port_arg, 10) catch {
        std.debug.print("Invalid port: {s}\n", .{port_arg});
        return;
    };

    var num_conns:   u32 = 50;
    var payload_size: u32 = 4096;
    var num_rounds:  u32 = 3;

    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--conns")) {
            if (iter.next()) |v| num_conns = std.fmt.parseInt(u32, v, 10) catch num_conns;
        } else if (std.mem.eql(u8, arg, "--bytes")) {
            if (iter.next()) |v| payload_size = std.fmt.parseInt(u32, v, 10) catch payload_size;
        } else if (std.mem.eql(u8, arg, "--rounds")) {
            if (iter.next()) |v| num_rounds = std.fmt.parseInt(u32, v, 10) catch num_rounds;
        }
    }

    const addr = Io.net.IpAddress.resolve(io, host_arg, port) catch |err| {
        std.debug.print("Cannot resolve {s}:{d}: {s}\n",
            .{ host_arg, port, @errorName(err) });
        return;
    };

    const payload = try allocator.alloc(u8, payload_size);
    defer allocator.free(payload);
    @memset(payload, 'X');

    std.debug.print(
        "\necho-bench  →  {s}:{d}   conns={d}  bytes={d}  rounds={d}\n\n",
        .{ host_arg, port, num_conns, payload_size, num_rounds },
    );

    for (0..num_rounds) |i|
        try runRound(io, addr, num_conns, payload, @intCast(i + 1));

    std.debug.print("\nDone.\n", .{});
}
