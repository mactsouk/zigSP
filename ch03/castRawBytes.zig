const std = @import("std");

const Header = extern struct {
    magic: u16,
    version: u8,
    command: u8,
};

pub fn main(_: std.process.Init.Minimal) void {
    const err = std.debug;
    // 1. Define the aligned bytes
    const raw_bytes align(@alignOf(Header)) = [_]u8{
        0x34,
        0x12,
        0x01,
        0x05,
    };
    const slice: []const u8 = &raw_bytes;

    // 2. The Fix: Chain @alignCast -> @ptrCast
    // @alignCast: Asserts the pointer is aligned to @alignOf(Header)
    // @ptrCast:   Converts the type from u8 to Header
    const header_ptr: *const Header = @ptrCast(@alignCast(slice.ptr));

    err.print("Method 1 (Pointer Cast):\n", .{});
    err.print(
        "  Magic: 0x{X}, Cmd: {}\n",
        .{ header_ptr.magic, header_ptr.command },
    );

    // --- Method 2: Safe Copy (unchanged) ---
    const big_buffer = [_]u8{ 0xFF, 0x34, 0x12, 0x01, 0x05 };
    const unaligned_slice = big_buffer[1..5];
    const safe_header = std.mem.bytesToValue(Header, unaligned_slice);

    err.print("\nMethod 2 (bytesToValue):\n", .{});
    err.print(
        "  Magic: 0x{X}, Cmd: {}\n",
        .{ safe_header.magic, safe_header.command },
    );
}
