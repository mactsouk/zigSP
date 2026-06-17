const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var cwdDir: std.Io.Dir = try std.Io.Dir.cwd().openDir(
        io,
        ".",
        .{ .iterate = true },
    );
    defer cwdDir.close(io);

    var cwdIterator = cwdDir.iterate();
    while (try cwdIterator.next(io)) |dirContent| {
        std.debug.print("{s}\n", .{dirContent.name});
    }

    std.debug.print("\n", .{});
    var rootDir: std.Io.Dir = try std.Io.Dir.openDirAbsolute(io, "/", .{ .iterate = true });
    defer rootDir.close(io);

    var rootIterator = rootDir.iterate();
    while (try rootIterator.next(io)) |dirContent| {
        std.debug.print("{s}\n", .{dirContent.name});
    }
}
