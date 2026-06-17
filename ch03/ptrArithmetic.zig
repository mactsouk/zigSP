const std = @import("std");

pub fn main(_: std.process.Init.Minimal) void {
    var arr = [_]i32{ 1, 2, 3, 4 };
    var ptrArr: [*]i32 = &arr;
    const first: [*]i32 = &arr;

    // Normal dereference syntax
    ptrArr[0] = -9;
    std.debug.print(
        "ptrArr[0]: {} , arr[0]: {}\n",
        .{ ptrArr[0], arr[0] },
    );
    std.debug.print("array: {any}\n", .{arr});

    // Pointer arithmetic
    for (0..arr.len) |i| {
        std.debug.print(
            "ptrArr[0]: {} , arr[i]: {}\n",
            .{ ptrArr[0], arr[i] },
        );
        // Points to the next array element
        ptrArr += 1;
    }

    // Pointer arithmetic
    var tmp: [*]i32 = undefined;
    for (0..arr.len) |i| {
        tmp = first + i;
        std.debug.print(
            "tmp[0]: {} , arr[i]: {}\n",
            .{ tmp[0], arr[i] },
        );
    }

    const myPtr = &arr;
    for (myPtr, 0..) |*item, i| {
        std.debug.print("Element {}: {} {}\n", .{ i, item, item.* });
    }

    const nullPtr: ?*i32 = null;
    if (nullPtr == null) {
        std.debug.print("The pointer is null.\n", .{});
    }
}
