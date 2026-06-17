const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    // 1. Setup Buffered Output
    var buffer: [4096]u8 = undefined;
    var stdout_impl = std.Io.File.stdout().writer(io, &buffer);
    const stdout = &stdout_impl.interface;
    defer stdout.flush() catch {};

    // 2. Parse Arguments
    // We set default values for our configuration.
    var count: usize = 1;
    var use_uppercase: bool = false;

    var iter = init.minimal.args.iterate();
    defer iter.deinit();

    // Skip the first argument (the program name itself)
    _ = iter.next();

    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "-u")) {
            use_uppercase = true;
        } else if (std.mem.eql(u8, arg, "-n")) {
            // If -n is found, the *next* argument must be the number.
            if (iter.next()) |num_str| {
                count = try std.fmt.parseInt(usize, num_str, 10);
            } else {
                std.debug.print(
                    "Error: -n requires a number argument.\n",
                    .{},
                );
                return error.InvalidArgs;
            }
        }
    }

    // 3. Execution Loop
    // We now loop 'count' times, respecting the user's wish.
    var i: usize = 0;
    while (i < count) : (i += 1) {
        var uuid: [16]u8 = undefined;
        // io.random() uses a PRNG seeded from a secure source —
        // fast but not guaranteed to make a syscall per invocation.
        // For UUIDs used as database IDs, session tokens, or any
        // security-sensitive context, use io.randomSecure(), which
        // always calls the OS entropy source (e.g. getrandom/arc4random)
        // and returns error.EntropyUnavailable on failure.
        try io.randomSecure(&uuid);

        // Version 4 and Variant stamping
        uuid[6] = (uuid[6] & 0x0f) | 0x40;
        uuid[8] = (uuid[8] & 0x3f) | 0x80;

        // We switch on the format string based on the flag.
        // {x} produces lowercase hex, {X} produces uppercase hex.
        if (use_uppercase) {
            try stdout.print(
                "{X:0>2}{X:0>2}{X:0>2}{X:0>2}-{X:0>2}{X:0>2}-" ++
                    "{X:0>2}{X:0>2}-{X:0>2}{X:0>2}-" ++
                    "{X:0>2}{X:0>2}{X:0>2}{X:0>2}{X:0>2}{X:0>2}\n",
                .{
                    uuid[0],  uuid[1],  uuid[2],  uuid[3],
                    uuid[4],  uuid[5],  uuid[6],  uuid[7],
                    uuid[8],  uuid[9],  uuid[10], uuid[11],
                    uuid[12], uuid[13], uuid[14], uuid[15],
                },
            );
        } else {
            try stdout.print(
                "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-" ++
                    "{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-" ++
                    "{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}\n",
                .{
                    uuid[0],  uuid[1],  uuid[2],  uuid[3],
                    uuid[4],  uuid[5],  uuid[6],  uuid[7],
                    uuid[8],  uuid[9],  uuid[10], uuid[11],
                    uuid[12], uuid[13], uuid[14], uuid[15],
                },
            );
        }
    }

    try stdout.flush();
}
