const std = @import("std");
// Zig 0.16:
// const c = @cImport({
//     @cInclude("unistd.h");
//     @cInclude("sys/wait.h");
// });
// Zig 0.17: zig translate-c -lc forkMe_c.h > forkMe_c.zig
const c = @import("forkMe_c.zig");

pub fn main(init: std.process.Init) !void {
    _ = init;
    const myPID = c.getpid();
    const pid = c.fork();
    if (pid < 0) {
        std.debug.print("Fork failed.\n", .{});
        return error.ForkFailed;
    } else if (pid == 0) {
        std.debug.print("Hello from the child process!\n", .{});
    } else {
        std.debug.print("Hello from the parent process!\n", .{});
        std.debug.print(
            "Parent PID: {} - Child PID: {}\n",
            .{ myPID, pid },
        );
        const wait_result = c.waitpid(pid, null, 0);
        if (wait_result < 0) {
            std.debug.print("waitpid failed.\n", .{});
        }
    }
}
