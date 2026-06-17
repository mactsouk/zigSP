const std = @import("std");
const builtin = @import("builtin");

pub fn main(_: std.process.Init.Minimal) void {
    // Our test value: 0x12345678
    // MSB: 12, LSB: 78
    const value: u32 = 0x12345678;

    // 1. Inspect Native Storage
    // This shows how your specific CPU (likely Little Endian) stores it currently.
    const native_bytes = std.mem.asBytes(&value);
    std.debug.print(
        "Native ({s}):   {x}\n",
        .{ @tagName(builtin.cpu.arch.endian()), native_bytes.* },
    );

    // 2. Force Big Endian (Network Byte Order)
    // We convert the native integer to Big Endian representation.
    // This should result in { 12, 34, 56, 78 } (Human readable order).
    const big_val = std.mem.nativeToBig(u32, value);
    const big_bytes = std.mem.asBytes(&big_val);
    std.debug.print("Big Endian:      {x}\n", .{big_bytes.*});

    // 3. Force Little Endian (ZIP Standard)
    // We convert the native integer to Little Endian representation.
    // This should result in { 78, 56, 34, 12 } (Reverse order).
    const little_val = std.mem.nativeToLittle(u32, value);
    const little_bytes = std.mem.asBytes(&little_val);
    std.debug.print("Little Endian:   {x}\n", .{little_bytes.*});
}
