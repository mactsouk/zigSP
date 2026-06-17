const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 2) {
        std.debug.print("Usage: {s} <file>\n", .{args[0]});
        return;
    }
    const filePath = args[1];
    const file = try std.Io.Dir.cwd().openFile(init.io, filePath, .{});
    defer file.close(init.io);
    const stat = try file.stat(init.io);

    const buffer = try allocator.alloc(u8, stat.size);
    defer allocator.free(buffer);

    _ = try file.readPositionalAll(init.io, buffer, 0);
    std.debug.print("File contents:\n{s}\n", .{buffer});
}
