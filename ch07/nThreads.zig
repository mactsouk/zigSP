const std = @import("std");

fn threadFunc(arg: usize) void {
    std.debug.print("{} ", .{arg});
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    if (argv.len < 2) {
        std.debug.print("Usage: {s} <N>\n", .{argv[0]});
        return;
    }

    const nStr = argv[1];
    const value = std.fmt.parseInt(usize, nStr, 10) catch {
        std.debug.print("Invalid number: {s}\n", .{nStr});
        return;
    };

    const threads = try allocator.alloc(std.Thread, value);
    defer allocator.free(threads);
    for (0..value) |i| {
        const thread = try std.Thread.spawn(.{}, threadFunc, .{i});
        threads[i] = thread;
    }

    for (0..value) |i| {
        threads[i].join();
    }

    std.debug.print("\nAll threads have finished.\n", .{});
}
