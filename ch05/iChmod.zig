const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len != 3) {
        std.debug.print("Usage: {s} <mode> <file>\n", .{args[0]});
        return error.InvalidArgs;
    }
    const modeStr = args[1];
    const filePath = args[2];

    const mode = std.fmt.parseInt(u16, modeStr, 8) catch {
        std.debug.print("Invalid mode: {s}\n", .{modeStr});
        return error.InvalidMode;
    };

    const file = std.Io.Dir.cwd().openFile(io, filePath, .{}) catch {
        std.debug.print("chmod failed for file: {s}\n", .{filePath});
        return error.ChmodFailed;
    };
    defer file.close(io);

    if (std.c.fchmod(file.handle, @as(std.posix.mode_t, mode)) != 0) {
        std.debug.print("chmod failed for file: {s}\n", .{filePath});
        return error.ChmodFailed;
    }

    std.debug.print(
        "Set permissions {s} for {s}\n",
        .{ modeStr, filePath },
    );
}
