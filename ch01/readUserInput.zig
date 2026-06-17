const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const stdout = std.Io.File.stdout();

    try stdout.writeStreamingAll(init.io, "What is your name? ");

    const name = try readLine(init.io, init.gpa);

    if (name) |n| {
        defer init.gpa.free(n);
        const clean_name = std.mem.trimEnd(u8, n, "\r\n");

        const msg = try std.fmt.allocPrint(init.gpa, "Hello, {s}! Welcome to Zig.\n", .{clean_name});
        defer init.gpa.free(msg);
        try stdout.writeStreamingAll(init.io, msg);
    } else {
        try stdout.writeStreamingAll(init.io, "\nNo input received.\n");
    }
}

fn readLine(io: std.Io, allocator: std.mem.Allocator) !?[]u8 {
    const stdin = std.Io.File.stdin();
    var list = std.ArrayList(u8).empty;
    errdefer list.deinit(allocator);

    while (true) {
        var byte: [1]u8 = undefined;
        const amt = stdin.readStreaming(io, &.{&byte}) catch |err|
            {
                if (err == error.EndOfStream) break;
                return err;
            };
        if (amt == 0) {
            if (list.items.len == 0) return null;
            break;
        }

        if (byte[0] == '\n') break;
        try list.append(allocator, byte[0]);
    }

    return try list.toOwnedSlice(allocator);
}
