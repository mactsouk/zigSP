const std = @import("std");

pub fn main(init: std.process.Init) !void {
    // Get the PATH environment variable from the environ map
    const pathEnv = init.environ_map.get("PATH") orelse {
        std.debug.print("Error: PATH variable not found\n", .{});
        return;
    };

    std.debug.print("PATH: {s}\n", .{pathEnv});
}
