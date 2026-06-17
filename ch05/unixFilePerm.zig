const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 2) {
        std.debug.print("Usage: {s} <path>\n", .{args[0]});
        return;
    }
    const path = args[1];

    const file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    defer file.close(io);

    const fileStat = try file.stat(io);
    const permissions = fileStat.permissions.toMode() & 0o7777;
    std.debug.print("File permissions (octal): {o}\n", .{permissions});

    if (permissions == 0o755) {
        std.debug.print("File permissions (octal): {o}\n", .{permissions});
    }
}
