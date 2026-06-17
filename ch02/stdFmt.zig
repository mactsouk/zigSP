const std = @import("std");

const User = struct {
    name: []const u8,
    id: u32,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    // page_allocator is used here for brevity before the full
    // allocator discussion in the next section. In production
    // code and in the rest of this book, prefer init.gpa.
    const allocator = std.heap.page_allocator;
    const stdout = std.Io.File.stdout();
    std.debug.print("Debug: Program started.\n", .{});

    // 2. Formatting numbers (Decimal, Hex, Binary, Octal)
    const number = 255;
    const msg_nums = try std.fmt.allocPrint(
        allocator,
        "Decimal: {d}, Hex: {x}, Binary: {b}, Octal: {o}\n",
        .{ number, number, number, number },
    );
    defer allocator.free(msg_nums);
    try stdout.writeStreamingAll(io, msg_nums);

    // 3. Formatting with precision and padding
    const pi = 3.14159;
    const msg_float = try std.fmt.allocPrint(
        allocator,
        "Pi (2 decimals): {d:.2} | Padded: {d: >10.2}\n",
        .{ pi, pi },
    );
    defer allocator.free(msg_float);
    try stdout.writeStreamingAll(io, msg_float);

    // 4. Formatting Structs and Arrays using {any}
    const user = User{ .name = "Alice", .id = 101 };
    const numbers = [_]u8{ 1, 2, 3 };

    // {any} recursively formats the structure
    const msg_struct = try std.fmt.allocPrint(
        allocator,
        "User: {any}, Array: {any}\n",
        .{ user, numbers },
    );
    defer allocator.free(msg_struct);
    try stdout.writeStreamingAll(io, msg_struct);

    // 5. Formatting into a fixed-size stack buffer (No allocation)
    var buffer: [64]u8 = undefined;
    const slice = try std.fmt.bufPrint(
        &buffer,
        "Stack buffer: {s}-{d}",
        .{ "Data", 42 },
    );
    try stdout.writeStreamingAll(io, slice);
    try stdout.writeStreamingAll(io, "\n");
}
