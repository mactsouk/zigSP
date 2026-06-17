const std = @import("std");

pub fn doesItExist(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch |e| switch (e) {
        error.FileNotFound => return false,
        else => return false,
    };
    return true;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 2) {
        std.debug.print("Usage: {s} <directory>\n", .{args[0]});
        return;
    }
    const directory = args[1];

    if (doesItExist(io, directory)) {
        std.debug.print("Path {s} already exists!\n", .{directory});
        return error.PathExists;
    }

    try std.Io.Dir.cwd().createDir(io, directory, .default_dir);
}
