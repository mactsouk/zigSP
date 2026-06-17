const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 2) {
        std.debug.print("Usage: {s} <file>\n", .{args[0]});
        return;
    }
    const filePath = args[1];

    // Open file for read+write (fails if file does not exist)
    const file = try std.Io.Dir.cwd().openFile(init.io, filePath, .{ .mode = .read_write });
    defer file.close(init.io);

    // Get current file size, then write at the end (append)
    const stat = try file.stat(init.io);
    try file.writePositionalAll(init.io, "Appended line\n", stat.size);
}
