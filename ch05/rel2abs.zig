const std = @import("std");

// Zig 0.16:
// const c = @cImport({
//     @cInclude("stdlib.h");
// });
// Zig 0.17: zig translate-c -lc rel2abs_c.h > rel2abs_c.zig
const c = @import("rel2abs_c.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len != 2) {
        std.debug.print("Usage: {s} <relative-path>\n", .{args[0]});
        return error.InvalidArgs;
    }

    const inputPath = args[1];

    // 1. C Implementation
    var c_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const resolvedPath = c.realpath(inputPath, &c_buffer);
    if (resolvedPath == null) {
        const err = std.c._errno().*;
        std.debug.print("C realpath() failed with errno {}\n", .{err});
    } else {
        const absPath = std.mem.span(resolvedPath);
        std.debug.print("C:    {s}\n", .{absPath});
    }

    // 2. Zig Native (Fixed Buffer)
    var zig_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const zig_path_len = std.Io.Dir.cwd().realPathFile(
        io,
        inputPath,
        &zig_buffer,
    ) catch |err| {
        std.debug.print(
            "Zig realpath failed: {s}\n",
            .{@errorName(err)},
        );
        return;
    };
    std.debug.print("Zig:  {s}\n", .{zig_buffer[0..zig_path_len]});

    // 3. Zig Native (Allocated)
    const absolutePath = std.Io.Dir.realPathFileAlloc(
        std.Io.Dir.cwd(),
        io,
        inputPath,
        allocator,
    ) catch |err| {
        std.debug.print(
            "Zig realpathAlloc failed: {s}\n",
            .{@errorName(err)},
        );
        return;
    };
    defer allocator.free(absolutePath);
    std.debug.print("Alloc: {s}\n", .{absolutePath});
}
