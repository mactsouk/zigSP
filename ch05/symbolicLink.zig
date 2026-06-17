const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 3) {
        std.debug.print(
            \\Usage: {s} [--dir] <target> <link_name>
            \\  --dir   : Create directory symlink (Windows)
            \\Example:
            \\  {s} source.txt link.txt
            \\  {s} --dir my_dir dir_link
            \\
        , .{ args[0], args[0], args[0] });
        return;
    }

    var is_dir_flag = false;
    var arg_index: usize = 1;

    if (std.mem.eql(u8, args[1], "--dir")) {
        is_dir_flag = true;
        arg_index = 2;

        if (args.len < 4) {
            std.debug.print("Missing arguments for --dir flag\n", .{});
            return error.InvalidArguments;
        }
    }

    const target = args[arg_index];
    const link_name = args[arg_index + 1];
    try std.Io.Dir.cwd().symLink(
        io,
        target,
        link_name,
        .{ .is_directory = is_dir_flag },
    );

    std.debug.print(
        "Created symlink: '{s}' -> '{s}'\n",
        .{ link_name, target },
    );
}
