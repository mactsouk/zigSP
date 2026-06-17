const std = @import("std");

pub fn main(init: std.process.Init) !void {
    // Customize this set to match your target password policy.
    const set = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*-_";
    const charsetLen = set.len;

    var stringLength: u32 = 16;
    var iter = init.minimal.args.iterate();
    defer iter.deinit();
    _ = iter.next();
    if (iter.next()) |arg| {
        stringLength = try std.fmt.parseInt(u32, arg, 10);
    }

    const result = try init.gpa.alloc(u8, stringLength);
    defer init.gpa.free(result);

    // Rejection sampling avoids modulo bias when mapping a uniform byte to the charset.
    const threshold = 256 - (256 % charsetLen);
    for (result) |*ch| {
        var byte: [1]u8 = undefined;
        while (true) {
            try init.io.randomSecure(&byte);
            if (byte[0] < threshold) {
                ch.* = set[byte[0] % charsetLen];
                break;
            }
        }
    }

    std.debug.print("Random string: {s}\n", .{result});
}
