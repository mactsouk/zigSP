const std = @import("std");
const distances = @import("distances");

pub fn main(_: std.process.Init.Minimal) !void {
    const allocator = std.heap.page_allocator;
    var a = [_]f64{ 1.0, 2.0, 3.0 };
    var b = [_]f64{ 2.0, 3.0, 4.0 };

    const ed = try distances.euclideanDistance(&a, &b);
    std.debug.print("Euclidean distance: {d:.5}\n", .{ed});
    const man = try distances.manhattanDistance(&a, &b);
    std.debug.print("Manhattan distance: {}\n", .{man});
    const che = try distances.chebyshevDistance(&a, &b);
    std.debug.print("Chebyshev distance: {}\n", .{che});
    const lcss = try distances.lcssDistance(allocator, &a, &b, 0.001);
    std.debug.print("LCSS distance: {d:.5}\n", .{lcss});
    const edr = try distances.edrDistance(allocator, &a, &b, 0.001);
    std.debug.print("EDR distance: {}\n", .{edr});
}
