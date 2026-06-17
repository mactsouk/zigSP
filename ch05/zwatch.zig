const std = @import("std");
const builtin = @import("builtin");
const c = @cImport({
    @cInclude("sys/event.h");
});

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 2) {
        const stderr = std.Io.File.stderr();
        try stderr.writeStreamingAll(io, "Usage: zwatch <directory1> [directory2] ...\n");
        std.process.exit(1);
    }

    const dirs = args[1..];
    const stdout = std.Io.File.stdout();

    if (builtin.os.tag == .linux) {
        try runInotify(io, stdout, dirs);
    } else if (builtin.os.tag == .macos or builtin.os.tag.isBSD()) {
        try runKqueue(io, stdout, dirs, allocator);
    } else {
        @compileError("Unsupported operating system");
    }
}

fn runInotify(
    io: std.Io,
    stdout: std.Io.File,
    dirs: []const [:0]const u8,
) !void {
    const linux = std.os.linux;
    const rc_init = linux.inotify_init1(linux.IN.CLOEXEC);
    const init_errno = std.posix.errno(rc_init);
    if (init_errno != .SUCCESS)
        return std.posix.unexpectedErrno(init_errno);
    const fd: std.posix.fd_t = @intCast(rc_init);
    defer _ = linux.close(fd);

    var msg_buf: [512]u8 = undefined;
    const msg = try std.fmt.bufPrint(
        &msg_buf,
        "zwatch: Monitoring via inotify (Linux) - {d} director{s}...\n",
        .{ dirs.len, if (dirs.len == 1) "y" else "ies" },
    );
    try stdout.writeStreamingAll(io, msg);

    for (dirs) |dir| {
        const rc_watch = linux.inotify_add_watch(
            fd,
            dir.ptr,
            linux.IN.MODIFY | linux.IN.CREATE | linux.IN.DELETE,
        );
        const watch_errno = std.posix.errno(rc_watch);
        if (watch_errno != .SUCCESS)
            return std.posix.unexpectedErrno(watch_errno);
        const dir_msg = try std.fmt.bufPrint(
            &msg_buf,
            "  Watching: {s}\n",
            .{dir},
        );
        try stdout.writeStreamingAll(io, dir_msg);
    }

    var buf: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;
    while (true) {
        const bytes_read = try std.posix.read(fd, &buf);
        var i: usize = 0;
        while (i < bytes_read) {
            const event = @as(
                *const linux.inotify_event,
                @ptrCast(@alignCast(&buf[i])),
            );
            if (event.len > 0) {
                const name_ptr = @as(
                    [*:0]const u8,
                    @ptrCast(&buf[i + @sizeOf(linux.inotify_event)]),
                );
                const name = std.mem.span(name_ptr);
                const event_msg = try std.fmt.bufPrint(
                    &msg_buf,
                    "Event detected on: {s}\n",
                    .{name},
                );
                try stdout.writeStreamingAll(io, event_msg);
            }
            i += @sizeOf(linux.inotify_event) + event.len;
        }
    }
}

fn runKqueue(
    io: std.Io,
    stdout: std.Io.File,
    dirs: []const [:0]const u8,
    allocator: std.mem.Allocator,
) !void {
    const kq = std.c.kqueue();
    if (kq == -1) return error.KqueueFailed;
    defer _ = std.c.close(kq);

    var msg_buf: [512]u8 = undefined;
    const msg = try std.fmt.bufPrint(
        &msg_buf,
        "zwatch: Monitoring via kqueue - {d} director{s}...\n",
        .{ dirs.len, if (dirs.len == 1) "y" else "ies" },
    );
    try stdout.writeStreamingAll(io, msg);

    var events: std.ArrayListUnmanaged(c.struct_kevent) = .empty;
    defer events.deinit(allocator);

    for (dirs) |dir| {
        const dir_fd = try std.posix.openat(
            std.posix.AT.FDCWD,
            dir,
            .{ .ACCMODE = .RDONLY },
            0,
        );
        // dir_fd must stay open for the lifetime of the monitoring
        // session; kqueue holds a reference to it. A production tool
        // would collect these fds and close them on SIGTERM/SIGINT
        // before exiting.

        const event = c.struct_kevent{
            .ident = @intCast(dir_fd),
            .filter = c.EVFILT_VNODE,
            .flags = c.EV_ADD | c.EV_ENABLE | c.EV_CLEAR,
            .fflags = c.NOTE_WRITE | c.NOTE_DELETE | c.NOTE_RENAME,
            .data = 0,
            .udata = null,
        };
        try events.append(allocator, event);

        const dir_msg = try std.fmt.bufPrint(
            &msg_buf,
            "  Watching: {s}\n",
            .{dir},
        );
        try stdout.writeStreamingAll(io, dir_msg);
    }

    _ = c.kevent(
        kq,
        events.items.ptr,
        @intCast(events.items.len),
        null,
        0,
        null,
    );

    while (true) {
        var event_list: [10]c.struct_kevent = undefined;
        const n = c.kevent(
            kq,
            null,
            0,
            &event_list,
            event_list.len,
            null,
        );
        if (n > 0) {
            for (0..@intCast(n)) |idx| {
                const evt = event_list[idx];
                const change_msg = try std.fmt.bufPrint(
                    &msg_buf,
                    "Changes detected in directory (fd: {d})\n",
                    .{evt.ident},
                );
                try stdout.writeStreamingAll(io, change_msg);
            }
        }
    }
}
