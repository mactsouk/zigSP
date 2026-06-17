const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(
        init.arena.allocator(),
    );

    if (args.len < 2) {
        std.debug.print("Usage: {s} <file>\n", .{args[0]});
        return;
    }
    const filePath = args[1];
    const file = try std.Io.Dir.cwd().openFile(init.io, filePath, .{});
    defer file.close(init.io);

    // In Zig 0.16, file I/O uses positional reads instead of seek+read.
    // Read 1 byte at offset 5 directly, without changing any seek position.
    var byte_buf: [1]u8 = undefined;
    const n = try file.readPositionalAll(init.io, &byte_buf, 5);
    if (n > 0) {
        std.debug.print("Byte at offset 5: 0x{x}\n", .{byte_buf[0]});
    } else {
        std.debug.print("File is shorter than 5 bytes.\n", .{});
    }

    // Get file size via stat
    const stat = try file.stat(init.io);
    std.debug.print("File size: {d} bytes\n", .{stat.size});
}
