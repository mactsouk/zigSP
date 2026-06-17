const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();
    const stdout = std.Io.File.stdout();
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 2) {
        const msg = try std.fmt.allocPrint(allocator, "Usage: {s} <path>...\n", .{args[0]});
        try stdout.writeStreamingAll(io, msg);
        return;
    }

    for (args[1..]) |arg| {
        const base = getBasename(arg);
        const line = try std.fmt.allocPrint(allocator, "{s}\n", .{base});
        try stdout.writeStreamingAll(io, line);
    }
}

fn getBasename(path: []const u8) []const u8 {
    // Edge case: Empty string -> "."
    if (path.len == 0) return ".";

    // 1. Trim trailing slashes (e.g., "dir///" -> "dir")
    var end = path.len;
    while (end > 0 and path[end - 1] == '/') {
        end -= 1;
    }

    // Edge case: String was all slashes (e.g. "///") -> "/"
    if (end == 0) {
        return "/";
    }

    // 2. Find the last slash *before* the end
    var start = end;
    while (start > 0) {
        if (path[start - 1] == '/') break;
        start -= 1;
    }

    return path[start..end];
}
