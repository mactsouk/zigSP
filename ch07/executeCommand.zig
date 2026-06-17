const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    // First command: Execute a process and ignore stdout and stderr
    const argv1 = [_][]const u8{ "ls", "./doesNotExist" };
    const proc1 = try std.process.run(
        allocator,
        io,
        .{ .argv = &argv1 },
    );
    defer allocator.free(proc1.stdout);
    defer allocator.free(proc1.stderr);

    switch (proc1.term) {
        .exited => |eCode| {
            if (eCode != 0) {
                std.debug.print(
                    "P1 did not exit cleanly with code {}\n",
                    .{eCode},
                );
            } else {
                std.debug.print("P1 completed successfully.\n", .{});
            }
        },
        .signal => {
            std.debug.print("P1 was killed by a signal.\n", .{});
        },
        .stopped => {
            std.debug.print("P1 was stopped.\n", .{});
        },
        .unknown => {
            std.debug.print("P1 terminated: unknown status.\n", .{});
        },
    }

    // Second command: Execute a process and capture stdout and stderr
    const argv2 = [_][]const u8{"uptime"};
    const proc2 = try std.process.run(
        allocator,
        io,
        .{ .argv = &argv2 },
    );
    defer allocator.free(proc2.stdout);
    defer allocator.free(proc2.stderr);

    switch (proc2.term) {
        .exited => |eCode| {
            if (eCode != 0) {
                std.debug.print(
                    "P2 did not exit cleanly with code {}\n",
                    .{eCode},
                );
                return;
            }
            std.debug.print("P2 completed successfully.\n", .{});
        },
        .signal => {
            std.debug.print("P2 was killed by a signal.\n", .{});
            return;
        },
        .stopped => {
            std.debug.print("P2 was stopped.\n", .{});
            return;
        },
        .unknown => {
            std.debug.print("P2 terminated: unknown status.\n", .{});
            return;
        },
    }

    std.debug.print("P2 stdout:\n{s}\n", .{proc2.stdout});
    std.debug.print("P2 stderr:\n{s}\n", .{proc2.stderr});
}
