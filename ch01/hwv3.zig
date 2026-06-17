const std = @import("std");

pub fn main(init: std.process.Init) !void {
    // 1. Explicitly allocate the buffer in userspace memory.
    //    This array will hold bytes temporarily before they go to the OS.
    var buffer: [4096]u8 = undefined;

    // 2. Initialize the specific buffered implementation.
    //    We attach the buffer to standard output, passing the Io instance.
    var stdout_impl = std.Io.File.stdout().writer(init.io, &buffer);

    // 3. Obtain the generic Writer interface.
    //    This provides the .print() and .flush() methods.
    const stdout = &stdout_impl.interface;

    // 4. Use formatted printing on the correct stream.
    //    We can now mix strings, numbers, and hex just like debug.print,
    //    but targeting actual stdout.
    try stdout.print("Hello {s}!\n", .{"Buffered World"});
    try stdout.print("Writing number: {d}\n", .{42});

    // 5. Vital: Flush the buffer!
    //    Because we are buffering, data sits in 'buffer' until we flush.
    try stdout.flush();
}
