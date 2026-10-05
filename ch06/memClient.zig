const std = @import("std");
// Zig 0.16:
// const c = @cImport({
//     @cInclude("sys/types.h");
//     @cInclude("sys/socket.h");
//     @cInclude("netdb.h");
//     @cInclude("arpa/inet.h");
// });
// Zig 0.17: zig translate-c -lc memClient_c.h > memClient_c.zig
const c = @import("memClient_c.zig");

/// Resolve a hostname or IP literal to an IPv4 address string.
/// Caller must free the returned slice.
fn resolveHostname(allocator: std.mem.Allocator, host: []const u8) ![]const u8 {
    // If it already looks like an IPv4 literal, return a copy.
    if (std.Io.net.IpAddress.parseIp4(host, 0)) |_| {
        return allocator.dupe(u8, host);
    } else |_| {}

    // Use getaddrinfo to resolve the hostname.
    // Zig 0.16: allocator.dupeZ(u8, host)
    const host_z = try allocator.dupeSentinel(u8, host, 0);
    defer allocator.free(host_z);

    var hints = std.mem.zeroes(c.struct_addrinfo);
    hints.ai_family = c.AF_INET; // IPv4 only
    hints.ai_socktype = c.SOCK_STREAM;

    var res: ?*c.struct_addrinfo = null;
    const rc = c.getaddrinfo(host_z.ptr, null, &hints, &res);
    if (rc != 0) return error.HostNotFound;
    defer c.freeaddrinfo(res);

    const sa = @as(*c.struct_sockaddr_in, @ptrCast(@alignCast(res.?.ai_addr)));
    var buf: [16]u8 = undefined;
    const ip = c.inet_ntop(c.AF_INET, &sa.sin_addr, &buf, buf.len);
    if (ip == null) return error.HostNotFound;

    const ip_str = std.mem.sliceTo(ip, 0);
    return allocator.dupe(u8, ip_str);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 4) {
        std.debug.print(
            "Usage: {s} <host> <port> <poll_count>\n",
            .{args[0]},
        );
        return;
    }

    const host = args[1];
    const port = try std.fmt.parseInt(u16, args[2], 10);
    const count = try std.fmt.parseInt(u32, args[3], 10);

    std.debug.print(
        "Polling {s}:{d} for {d} samples...\n",
        .{ host, port, count },
    );

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        pollServer(io, init.gpa, host, port) catch |err| {
            std.debug.print("Poll {d} failed: {}\n", .{ i + 1, err });
        };

        if (i < count - 1) {
            try std.Io.sleep(io, std.Io.Duration.fromSeconds(1), .awake);
        }
    }
}

fn pollServer(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
) !void {
    const ip = try resolveHostname(allocator, host);
    defer allocator.free(ip);
    const address = try std.Io.net.IpAddress.parseIp4(ip, port);
    const stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var rbuf: [64]u8 = undefined;
    var data: [1024]u8 = undefined;
    var reader_impl = stream.reader(io, &rbuf);
    const reader = &reader_impl.interface;

    const bytes_read = try reader.readSliceShort(&data);
    if (bytes_read == 0) return error.EmptyResponse;

    const parsed = try std.json.parseFromSlice(
        struct {
            os: []const u8,
            used_mb: u64,
            total_mb: u64,
            timestamp: i64,
        },
        allocator,
        data[0..bytes_read],
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const stats = parsed.value;
    std.debug.print("[{d}] {s} Memory: {d}/{d} MB ({d}%)\n", .{
        stats.timestamp,
        stats.os,
        stats.used_mb,
        stats.total_mb,
        (stats.used_mb * 100) / stats.total_mb,
    });
}
