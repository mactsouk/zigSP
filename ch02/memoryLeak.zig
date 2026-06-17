const std = @import("std");

// The helper function: computes 'n' Fibonacci numbers.
// It asks for an allocator, meaning the CALLER owns the resulting memory.
fn computeFibonacci(allocator: std.mem.Allocator, n: usize) ![]u32 {
    const list = try allocator.alloc(u32, n);

    if (n > 0) list[0] = 0;
    if (n > 1) list[1] = 1;

    for (2..n) |i| {
        list[i] = list[i - 1] + list[i - 2];
    }

    return list;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    // 1. Initialize the Debug Allocator (replaces GeneralPurposeAllocator in 0.16).
    // This allocator is designed to catch safety issues like double-frees and leaks.
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();

    // 2. Ensure we check for leaks when main exits.
    defer {
        const deinit_status = gpa.deinit();
        // If a leak is found, we panic to alert the developer.
        if (deinit_status == .leak) {
            std.debug.print("Error: Memory leak detected in main!\n", .{});
        }
    }

    // 3. Obtain a buffered writer for standard output
    var buf: [256]u8 = undefined;
    var w_impl = std.Io.File.stdout().writer(io, &buf);
    const stdout = &w_impl.interface;
    defer stdout.flush() catch {};

    // 4. Run the logic (Correctly managed)
    const n = 10;
    const fib_sequence = try computeFibonacci(allocator, n);

    // We remember to free the memory!
    defer allocator.free(fib_sequence);

    try stdout.print("Fibonacci sequence ({d}): {any}\n", .{ n, fib_sequence });
}

// --- The Test Scenario (Intentionally Broken) ---

test "leak from helper function" {
    const testing = std.testing;

    // The test runner uses a special allocator that reports leaks automatically.
    const fib_sequence = try computeFibonacci(testing.allocator, 10);

    // BUG: We intentionally forget to free 'fib_sequence' here!
    // defer testing.allocator.free(fib_sequence);

    // The logic still works...
    try testing.expectEqual(@as(u32, 34), fib_sequence[9]);
}
