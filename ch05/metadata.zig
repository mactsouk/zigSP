const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 2) {
        std.debug.print("Usage: {s} <path>\n", .{args[0]});
        return;
    }
    const path = args[1];

    const file = try std.Io.Dir.cwd().openFile(
        io,
        path,
        .{ .mode = .read_only },
    );
    defer file.close(io);

    const meta = try file.stat(io);

    std.debug.print("File: {s}\n", .{path});
    std.debug.print("Size: {} bytes\n", .{meta.size});
    std.debug.print(
        "Permissions: 0o{o}\n",
        .{meta.permissions.toMode()},
    );
    std.debug.print("Last accessed: {?}\n", .{meta.atime});
    std.debug.print("Last modified: {}\n", .{meta.mtime});
    std.debug.print("Created: {}\n", .{meta.ctime});
    std.debug.print("Kind: {}\n", .{meta.kind});
}
