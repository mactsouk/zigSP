const std = @import("std");

/// A simple addition function
fn add(a: i32, b: i32) i32 {
    return a + b;
}

/// A function with a conditional branch
fn maybeDouble(value: i32, should_double: bool) i32 {
    if (should_double) {
        return value * 2;
    } else {
        // This branch is the "Dead Zone" we will discover later
        return value;
    }
}

// Test Group A: Math operations
test "math - simple addition" {
    try std.testing.expectEqual(@as(i32, 10), add(5, 5));
}

test "math - verify doubling" {
    // We only test the 'true' case here
    try std.testing.expectEqual(@as(i32, 8), maybeDouble(4, true));
}

// Test Group B: Utility checks (unrelated to math)
test "utility - placeholder" {
    try std.testing.expect(true);
}
