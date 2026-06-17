const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const file_result = std.Io.Dir.cwd().createFile(
        init.io,
        "/tmp/empty.txt",
        .{
            .exclusive = true,
            .truncate = false,
        },
    ) catch |err| {
        if (err == error.PathAlreadyExists) {
            std.debug.print("File already exists.\n", .{});
            return;
        } else {
            return err;
        }
    };

    defer file_result.close(init.io);
    std.debug.print("Created empty file.\n", .{});
}
