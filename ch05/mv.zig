const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len != 3) {
        std.debug.print("Usage: {s} <source> <dest>\n", .{args[0]});
        return error.InvalidArgs;
    }

    const src = args[1];
    const dst = args[2];
    const cwd = std.Io.Dir.cwd();
    if (std.Io.Dir.rename(cwd, src, cwd, dst, io)) |_| {
        return;
    } else |err| {
        std.debug.print("Error: {}\n", .{err});
    }
}
