const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 2) {
        std.debug.print("Usage: {s} <path>\n", .{args[0]});
        return;
    }
    const path = args[1];

    // follow_symlinks = false uses lstat(2) semantics so .sym_link
    // is reachable. openFile() + stat() would follow the link and
    // report the target type instead.
    const meta = try std.Io.Dir.cwd().statFile(
        io,
        path,
        .{ .follow_symlinks = false },
    );

    switch (meta.kind) {
        .file => std.debug.print("{s} is a regular file.\n", .{path}),
        .directory => std.debug.print("{s} is a directory.\n", .{path}),
        .sym_link => std.debug.print(
            "{s} is a symbolic link.\n",
            .{path},
        ),
        else => std.debug.print(
            "{s} is some other kind of file.\n",
            .{path},
        ),
    }
}
