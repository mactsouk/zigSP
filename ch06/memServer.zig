const std = @import("std");
const builtin = @import("builtin");
// Zig 0.16:
// const c = @cImport({
//     @cInclude("time.h");
// });
// Zig 0.17: zig translate-c -lc memServer_c.h > memServer_c.zig
const c = @import("memServer_c.zig");

const MemStats = struct {
    os: []const u8,
    used_mb: u64,
    total_mb: u64,
    timestamp: i64,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 8080);
    var server = try address.listen(io, .{});
    defer server.deinit(io);

    std.debug.print("Memory Service listening on 127.0.0.1:8080...\n", .{});

    while (true) {
        const stream = server.accept(io) catch |err| {
            std.debug.print("Accept error: {}\n", .{err});
            continue;
        };
        defer stream.close(io);

        const stats = try getMemoryStats(io, allocator);
        const json_str = try std.fmt.allocPrint(
            allocator,
            "{f}\n",
            .{std.json.fmt(stats, .{})},
        );
        defer allocator.free(json_str);

        var wbuf: [4096]u8 = undefined;
        var writer_impl = stream.writer(io, &wbuf);
        const writer = &writer_impl.interface;
        try writer.writeAll(json_str);
        try writer.flush();
    }
}

fn getMemoryStats(io: std.Io, allocator: std.mem.Allocator) !MemStats {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_REALTIME, &ts);

    var stats = MemStats{
        .os = @tagName(builtin.os.tag),
        .used_mb = 0,
        .total_mb = 0,
        .timestamp = @as(i64, ts.tv_sec),
    };

    switch (builtin.os.tag) {
        .linux => {
            const file = try std.Io.Dir.cwd().openFile(io, "/proc/meminfo", .{});
            defer file.close(io);
            var buf: [4096]u8 = undefined;
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

fn getSysctl(io: std.Io, allocator: std.mem.Allocator, name: []const u8) !u64 {
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
