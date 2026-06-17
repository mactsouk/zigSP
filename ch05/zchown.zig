const std = @import("std");
const builtin = @import("builtin");

const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
});

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const stdout = std.Io.File.stdout();
    const stderr = std.Io.File.stderr();

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len != 4) {
        try stderr.writeStreamingAll(
            io,
            "Usage: zchown <uid> <gid> <file>\n",
        );
        std.process.exit(1);
    }

    // uid_t and gid_t are available directly in the posix namespace
    const uid = std.fmt.parseInt(c.uid_t, args[1], 10) catch {
        try stderr.writeStreamingAll(io, "Error: Invalid UID\n");
        return;
    };

    const gid = std.fmt.parseInt(c.gid_t, args[2], 10) catch {
        try stderr.writeStreamingAll(io, "Error: Invalid GID\n");
        return;
    };

    const path = args[3];

    // Produce a null-terminated copy; fchownat expects a C string.
    var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch {
        try stderr.writeStreamingAll(io, "Error: path too long\n");
        return;
    };

    // fchownat is the modern POSIX primitive.
    // AT_FDCWD (File Descriptor Current Working Directory) tells the kernel
    // to resolve 'path' relative to the current directory, like standard chown.
    // The 0 flag indicates we follow symlinks; use AT_SYMLINK_NOFOLLOW for lchown behavior.
    const result = c.fchownat(c.AT_FDCWD, path_z.ptr, uid, gid, 0);
    if (result != 0) {
        const err: std.posix.E = @enumFromInt(std.c._errno().*);
        var msg_buf: [256]u8 = undefined;
        const msg = try std.fmt.bufPrint(
            &msg_buf,
            "zchown: error: {s}\n",
            .{@tagName(err)},
        );
        try stderr.writeStreamingAll(io, msg);
        std.process.exit(1);
    }

    var success_buf: [256]u8 = undefined;
    const success_msg = try std.fmt.bufPrint(
        &success_buf,
        "Changed {s} to {d}:{d}\n",
        .{ path, uid, gid },
    );
    try stdout.writeStreamingAll(io, success_msg);
}
