const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const file = try std.Io.Dir.cwd().createFile(
        init.io,
        "/tmp/empty.txt",
        .{
            .truncate = true,
        },
    );
    defer file.close(init.io);
    std.debug.print("Created empty file: /tmp/empty.txt\n", .{});
}
