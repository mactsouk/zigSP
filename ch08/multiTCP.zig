const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const MemStats = struct {
    os: []const u8,
    used_mb: u64,
    total_mb: u64,
    timestamp: i64,
};

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = init.io;

    const addresses = [_][]const u8{
        "127.0.0.1",
        "192.168.1.168", // replace with your actual IP
    };

    var threads: [addresses.len]std.Thread = undefined;

    for (addresses, 0..) |addr_str, i| {
        const address = try Io.net.IpAddress.parseIp4(addr_str, 8080);
        const server = try address.listen(io, .{});
        std.debug.print(
            "Memory Service listening on {s}:8080...\n",
            .{addr_str},
        );
        threads[i] = try std.Thread.spawn(
            .{},
            serveLoop,
            .{ io, server, allocator },
        );
    }

    for (&threads) |*t| t.join();
}

fn serveLoop(io: Io, server: Io.net.Server, allocator: std.mem.Allocator) void {
    var srv = server;
    defer srv.deinit(io);
    while (true) {
        const stream = srv.accept(io) catch |err| {
            std.debug.print("Accept error: {}\n", .{err});
            continue;
        };
        defer stream.close(io);
        const stats = getMemoryStats(io, allocator) catch |err| {
            std.debug.print("Stats error: {}\n", .{err});
            continue;
        };
        const json_str = std.fmt.allocPrint(
            allocator,
            "{f}\n",
            .{std.json.fmt(stats, .{})},
        ) catch continue;
        defer allocator.free(json_str);

        var wbuf: [4096]u8 = undefined;
        var w = stream.writer(io, &wbuf);
        w.interface.writeAll(json_str) catch |err| {
            std.debug.print("Write error: {}\n", .{err});
            continue;
        };
        w.interface.flush() catch {};
    }
}

fn getMemoryStats(io: Io, allocator: std.mem.Allocator) !MemStats {
    var stats = MemStats{
        .os = @tagName(builtin.os.tag),
        .used_mb = 0,
        .total_mb = 0,
        .timestamp = unixNow(),
    };

    switch (builtin.os.tag) {
        .linux => {
            var buf: [4096]u8 = undefined;
            const file = try std.Io.Dir.cwd().openFile(io, "/proc/meminfo", .{});
            defer file.close(io);
            const n = try file.readPositionalAll(io, &buf, 0);
            const content = buf[0..n];
            var total_kb: u64 = 0;
            var avail_kb: u64 = 0;
            var lines = std.mem.tokenizeScalar(u8, content, '\n');
            while (lines.next()) |line| {
                if (std.mem.startsWith(u8, line, "MemTotal:")) total_kb = parseNumber(line);
                if (std.mem.startsWith(u8, line, "MemAvailable:")) avail_kb = parseNumber(line);
            }
            stats.total_mb = total_kb / 1024;
            stats.used_mb = (total_kb - avail_kb) / 1024;
        },
        .macos => {
            const total_bytes = try getSysctl(io, allocator, "hw.memsize");
            const page_size = try getSysctl(io, allocator, "hw.pagesize");
            const vm_stat = try std.process.run(allocator, io, .{
                .argv = &[_][]const u8{"vm_stat"},
            });
            defer {
                allocator.free(vm_stat.stdout);
                allocator.free(vm_stat.stderr);
            }
            var active: u64 = 0;
            var wired: u64 = 0;
            var compressed: u64 = 0;
            var lines = std.mem.tokenizeScalar(u8, vm_stat.stdout, '\n');
            while (lines.next()) |line| {
                if (std.mem.containsAtLeast(u8, line, 1, "Pages active:")) active = parseNumber(line);
                if (std.mem.containsAtLeast(u8, line, 1, "Pages wired down:")) wired = parseNumber(line);
                if (std.mem.containsAtLeast(u8, line, 1, "Pages occupied by compressor:")) compressed = parseNumber(line);
            }
            stats.total_mb = total_bytes / 1024 / 1024;
            stats.used_mb = (active + wired + compressed) * page_size / 1024 / 1024;
        },
        else => return error.UnsupportedOs,
    }
    return stats;
}

fn getSysctl(io: Io, allocator: std.mem.Allocator, name: []const u8) !u64 {
    const res = try std.process.run(allocator, io, .{
        .argv = &[_][]const u8{ "sysctl", "-n", name },
    });
    defer {
        allocator.free(res.stdout);
        allocator.free(res.stderr);
    }
    return try std.fmt.parseInt(u64, std.mem.trim(u8, res.stdout, " \n\r\t"), 10);
}

fn parseNumber(line: []const u8) u64 {
    var parts = std.mem.tokenizeAny(u8, line, " .:");
    while (parts.next()) |part| {
        if (std.fmt.parseInt(u64, part, 10)) |val| return val else |_| continue;
    }
    return 0;
}

fn unixNow() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return ts.sec;
}
