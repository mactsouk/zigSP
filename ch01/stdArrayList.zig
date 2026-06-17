const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    // 1. Initialize Unmanaged ArrayList
    var numbers = std.ArrayList(i32).empty;
    defer numbers.deinit(allocator);

    const stdout = std.Io.File.stdout();
    try stdout.writeStreamingAll(init.io, "Adding numbers 0, 10, 20, 30, 40...\n");

    // 2. Append
    var i: i32 = 0;
    while (i < 5) : (i += 1) {
        try numbers.append(allocator, i * 10);
    }

    // 3. Modify
    if (numbers.items.len > 2) {
        numbers.items[2] = 999;
        try stdout.writeStreamingAll(init.io, "Modified index 2 to 999.\n");
    }

    // 4. Iterate and Print
    try stdout.writeStreamingAll(init.io, "List contents: ");
    for (numbers.items) |num| {
        const num_str = try std.fmt.allocPrint(allocator, "{d} ", .{num});
        defer allocator.free(num_str);
        try stdout.writeStreamingAll(init.io, num_str);
    }
    try stdout.writeStreamingAll(init.io, "\n");

    // 5. Pop (returns optional ?i32)
    const last = numbers.pop();
    const pop_msg = try std.fmt.allocPrint(allocator, "Popped last item: {?d}\n", .{last});
    defer allocator.free(pop_msg);
    try stdout.writeStreamingAll(init.io, pop_msg);

    const len_msg = try std.fmt.allocPrint(allocator, "Final count: {d}\n", .{numbers.items.len});
    defer allocator.free(len_msg);
    try stdout.writeStreamingAll(init.io, len_msg);
}
