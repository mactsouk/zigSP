const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        std.debug.print("Usage: {s} <file1>\n", .{args[0]});
        return;
    }
    const filePath = args[1];

    const file = std.Io.Dir.cwd().createFile(init.io, filePath, .{
        .exclusive = true,
        .truncate = false,
    }) catch |err| {
        if (err == error.PathAlreadyExists) {
            std.debug.print("File already exists.\n", .{});
            return;
        } else {
            return err;
        }
    };
    defer file.close(init.io);
    try file.writeStreamingAll(init.io, "Writing to the file.\n");
}
