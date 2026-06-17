const std = @import("std");

pub fn main(init: std.process.Init) !void {
    // 1. Allocate buffers for the streams
    // We need two separate buffers so the streams don't mix in memory.
    var out_buf: [4096]u8 = undefined;
    var err_buf: [4096]u8 = undefined;

    // 2. Initialize Buffered Writers
    // We call .writer() on the File handle, passing io and the buffer slice.
    var stdout_impl = std.Io.File.stdout().writer(init.io, &out_buf);
    var stderr_impl = std.Io.File.stderr().writer(init.io, &err_buf);

    // 3. Get the Generic Writer Interfaces
    const stdout = &stdout_impl.interface;
    const stderr = &stderr_impl.interface;

    var i: usize = 0;
    while (i < 5) : (i += 1) {
        try stdout.print("OUT: This is stdout message #{d}\n", .{i});
        try stderr.print("ERR: This is stderr warning #{d}\n", .{i});
    }

    // 4. Flush to ensure all bytes leave the buffers
    try stdout.flush();
    try stderr.flush();
}
