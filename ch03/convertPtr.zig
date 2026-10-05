const std = @import("std");

// Zig 0.16:
// const c = @cImport({
//     @cInclude("stdio.h");
// });
// Zig 0.17: zig translate-c -lc convertPtr_c.h > convertPtr_c.zig
const c = @import("convertPtr_c.zig");

pub fn printC(s: [*:0]const u8) c_int {
    return c.printf("%s\n", s);
}

pub fn main(_: std.process.Init.Minimal) !void {
    const allocator = std.heap.page_allocator;
    const dir = "/usr";
    const util = "ls";

    _ = printC(dir);

    // 1. Initialization: Use '.empty' instead of '.init(allocator)'
    // The struct no longer holds the allocator field.
    var pathBuf = std.ArrayList(u8).empty;

    // 2. Deinit: You must pass the allocator here
    defer pathBuf.deinit(allocator);

    // 3. Append: You must pass the allocator to every method that might resize memory
    try pathBuf.appendSlice(allocator, dir);
    try pathBuf.append(allocator, '/');
    try pathBuf.appendSlice(allocator, util);

    const fullPath = pathBuf.items;
    std.debug.print("Zig Slice: {s}\n", .{fullPath});

    // Manual C-String conversion
    const buffer = try allocator.alloc(u8, fullPath.len + 1);
    defer allocator.free(buffer);

    std.mem.copyForwards(u8, buffer[0..fullPath.len], fullPath);
    buffer[fullPath.len] = 0;

    // 4. Casting: Remember to cast .ptr, not the slice itself
    _ = printC(@as([*:0]const u8, @ptrCast(buffer.ptr)));
}
