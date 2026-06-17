const std = @import("std");
const builtin = @import("builtin");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    while (true) {
        printUsedMemory(io, allocator) catch |err| {
            std.debug.print("Error: {}\n", .{err});
        };
        try std.Io.sleep(io, std.Io.Duration.fromSeconds(2), .awake);
    }
}

fn printUsedMemory(io: std.Io, allocator: std.mem.Allocator) !void {
    const ts = std.Io.Timestamp.now(io, .real);
    const now: i64 = ts.toSeconds();

    switch (builtin.os.tag) {
        .linux => {
            const file = try std.Io.Dir.cwd().openFile(
                io,
                "/proc/meminfo",
                .{},
            );
            defer file.close(io);
            var buf: [4096]u8 = undefined;
            const n = try file.readPositionalAll(io, &buf, 0);
            if (n >= buf.len)
                std.debug.print(
                    "warning: /proc/meminfo may be truncated\n",
                    .{},
                );
            const content = buf[0..n];
            var total: u64 = 0;
            var available: u64 = 0;

            var lines = std.mem.tokenizeScalar(u8, content, '\n');
            while (lines.next()) |line| {
                if (std.mem.startsWith(u8, line, "MemTotal:")) {
                    total = parseNumber(line);
                } else if (std.mem.startsWith(
                    u8,
                    line,
                    "MemAvailable:",
                )) {
                    available = parseNumber(line);
                }
            }

            const used_mb = (total - available) / 1024;
            const total_mb = total / 1024;
            std.debug.print(
                "[{d}] Linux Used RAM: {d} MB / {d} MB\n",
                .{ now, used_mb, total_mb },
            );
        },
        .macos => {
            const total_bytes = try getSysctl(
                io,
                allocator,
                "hw.memsize",
            );
            const page_size = try getSysctl(
                io,
                allocator,
                "hw.pagesize",
            );
            const vm_stat_cmd = try std.process.run(allocator, io, .{
                .argv = &[_][]const u8{"vm_stat"},
            });
            defer {
                allocator.free(vm_stat_cmd.stdout);
                allocator.free(vm_stat_cmd.stderr);
            }

            var active_pages: u64 = 0;
            var wired_pages: u64 = 0;
            var compressed_pages: u64 = 0;

            var lines = std.mem.tokenizeScalar(u8, vm_stat_cmd.stdout, '\n');
            while (lines.next()) |line| {
                if (std.mem.containsAtLeast(u8, line, 1, "Pages active:")) {
                    active_pages = parseNumber(line);
                } else if (std.mem.containsAtLeast(
                    u8,
                    line,
                    1,
                    "Pages wired down:",
                )) {
                    wired_pages = parseNumber(line);
                } else if (std.mem.containsAtLeast(
                    u8,
                    line,
                    1,
                    "Pages occupied by compressor:",
                )) {
                    compressed_pages = parseNumber(line);
                }
            }

            const used_bytes = (active_pages + wired_pages + compressed_pages) * page_size;
            const used_mb = used_bytes / 1024 / 1024;
            const total_mb = total_bytes / 1024 / 1024;
            std.debug.print(
                "[{d}] macOS Used RAM: {d} MB / {d} MB\n",
                .{ now, used_mb, total_mb },
            );
        },
        else => @compileError("Unsupported OS"),
    }
}

fn getSysctl(
    io: std.Io,
    allocator: std.mem.Allocator,
    name: []const u8,
) !u64 {
    const result = try std.process.run(allocator, io, .{
        .argv = &[_][]const u8{ "sysctl", "-n", name },
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    return try std.fmt.parseInt(
        u64,
        std.mem.trim(u8, result.stdout, " \n\r\t"),
        10,
    );
}

fn parseNumber(line: []const u8) u64 {
    var parts = std.mem.tokenizeAny(u8, line, " .:");
    while (parts.next()) |part| {
        if (std.fmt.parseInt(u64, part, 10)) |val| return val else |_| continue;
    }
    return 0;
}
