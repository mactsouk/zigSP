const std = @import("std");
const Io = std.Io;

fn saveFile(io: Io, data: []const u8, name: []const u8) !void {
    const file = try Io.Dir.cwd().createFile(io, name, .{});
    defer file.close(io);

    try file.writeStreamingAll(io, data);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    const data = "Hello from Zig 0.16 async I/O!\n";

    // Launch two file writes concurrently (files land in /tmp)
    var task_a = io.async(saveFile, .{ io, data, "/tmp/output_a.txt" });
    defer _ = task_a.cancel(io) catch {};

    var task_b = io.async(saveFile, .{ io, data, "/tmp/output_b.txt" });
    defer _ = task_b.cancel(io) catch {};

    // Wait for both
    try task_a.await(io);
    try task_b.await(io);

    try std.Io.File.stdout().writeStreamingAll(io, "Both files written successfully!\n");
}
