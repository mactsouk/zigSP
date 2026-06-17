const std = @import("std");
const zuuid = @import("zuuid");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var iter = init.minimal.args.iterate();
    defer iter.deinit();
    _ = iter.next(); // skip program name

    var count: usize = 1;
    var use_uppercase: bool = false;

    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "-u")) {
            use_uppercase = true;
        } else if (std.mem.eql(u8, arg, "-n")) {
            if (iter.next()) |num_str| {
                count = try std.fmt.parseInt(usize, num_str, 10);
            }
        }
    }

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const id = zuuid.Uuid.v4(io);

        if (use_uppercase) {
            std.debug.print("{f}\n", .{id.fmtUpper()});
        } else {
            std.debug.print("{f}\n", .{id});
        }
    }
}
