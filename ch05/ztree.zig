const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var show_all = false;
    var max_depth: ?usize = null;
    var start_path: []const u8 = ".";

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--all") or std.mem.eql(u8, arg, "-a")) {
            show_all = true;
        } else if (std.mem.eql(u8, arg, "-L")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: missing depth value after -L\n", .{});
                return error.MissingDepthValue;
            }
            max_depth = try std.fmt.parseInt(usize, args[i], 10);
        } else if (arg.len > 0 and arg[0] == '-') {
            std.debug.print("Usage: tree [--all] [-L <depth>] [path]\n", .{});
            return error.InvalidArgument;
        } else {
            start_path = arg;
        }
    }

    var buf: [4096]u8 = undefined;
    var w_impl = std.Io.File.stdout().writer(io, &buf);
    const stdout = &w_impl.interface;

    var root_dir = try std.Io.Dir.cwd().openDir(
        io,
        start_path,
        .{ .iterate = true },
    );
    defer root_dir.close(io);

    try stdout.print("{s}\n", .{start_path});
    try printTree(
        allocator,
        io,
        root_dir,
        0,
        "",
        show_all,
        max_depth,
        stdout,
    );
    try stdout.flush();
}

const DirEntry = struct {
    name: []const u8,
    is_dir: bool,
    symlink_target: ?[]const u8 = null,
};

fn printTree(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    depth: usize,
    prefix: []const u8,
    show_all: bool,
    max_depth: ?usize,
    stdout: *std.Io.Writer,
) !void {
    if (max_depth) |limit| {
        if (depth >= limit) return;
    }

    var entries: std.ArrayListUnmanaged(DirEntry) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (!show_all and entry.name.len > 0 and entry.name[0] == '.')
            continue;

        const name_copy = try allocator.dupe(u8, entry.name);

        if (entry.kind == .sym_link) {
            // Resolve the link target for display only; ztree
            //  does not recurse into symlinked directories to avoid
            // infinite loops on cyclic links.
            var link_buf: [4096]u8 = undefined;
            const target = dir.readLink(io, entry.name, &link_buf) catch
                null;
            const target_copy = if (target) |len|
                try allocator.dupe(u8, link_buf[0..len])
            else
                null;
            try entries.append(allocator, .{
                .name = name_copy,
                .is_dir = false,
                .symlink_target = target_copy,
            });
        } else {
            try entries.append(
                allocator,
                .{
                    .name = name_copy,
                    .is_dir = (entry.kind == .directory),
                },
            );
        }
    }

    std.mem.sort(DirEntry, entries.items, {}, struct {
        fn lessThan(_: void, a: DirEntry, b: DirEntry) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);

    const count = entries.items.len;
    for (entries.items, 0..) |item, index| {
        const is_last = (index == count - 1);
        const connector = if (is_last) "└── " else "├── ";
        if (item.symlink_target) |target| {
            try stdout.print(
                "{s}{s}{s} -> {s}\n",
                .{ prefix, connector, item.name, target },
            );
        } else {
            try stdout.print(
                "{s}{s}{s}\n",
                .{ prefix, connector, item.name },
            );
        }

        if (item.is_dir) {
            const extension = if (is_last) "    " else "│   ";
            const new_prefix = try std.fmt.allocPrint(
                allocator,
                "{s}{s}",
                .{ prefix, extension },
            );
            if (dir.openDir(
                io,
                item.name,
                .{ .iterate = true },
            )) |sub_dir| {
                var sub_dir_mut = sub_dir;
                defer sub_dir_mut.close(io);
                try printTree(
                    allocator,
                    io,
                    sub_dir_mut,
                    depth + 1,
                    new_prefix,
                    show_all,
                    max_depth,
                    stdout,
                );
            } else |_| {}
        }
    }
}
