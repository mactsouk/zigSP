const std = @import("std");

pub fn doesItExist(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

pub fn isFile(io: std.Io, path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return stat.kind == .file;
}

pub fn isExecutable(io: std.Io, path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;

    if (@import("builtin").os.tag == .windows) {
        return doesItExist(io, path);
    }

    const mode = stat.permissions.toMode();
    return (mode & 0o111) != 0;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var iter = init.minimal.args.iterate();
    defer iter.deinit();
    const prog_name = iter.next() orelse "zwhich";

    const command = iter.next() orelse {
        std.debug.print("Usage: {s} <command>\n", .{prog_name});
        return;
    };

    const path_env = init.environ_map.get("PATH") orelse {
        std.debug.print("Error: PATH environment variable not set\n", .{});
        return error.MissingEnvironment;
    };

    var buffer: [4096]u8 = undefined;
    var stdout_impl = std.Io.File.stdout().writer(io, &buffer);
    const stdout = &stdout_impl.interface;
    defer stdout.flush() catch {};

    var dirs = std.mem.splitScalar(u8, path_env, ':');
    var found = false;

    while (dirs.next()) |dir| {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, command }) catch continue;

        if (doesItExist(io, full_path) and
            isFile(io, full_path) and
            isExecutable(io, full_path))
        {
            try stdout.print("{s}\n", .{full_path});
            found = true;
            break;
        }
    }

    if (!found) {
        std.log.err("Command '{s}' not found in PATH", .{command});
        return error.FileNotFound;
    }
}

test "filesystem helpers" {
    const testing = std.testing;

    // Obtain an Io instance for the test
    var t: std.Io.Threaded = .init_single_threaded;
    const io = t.io();

    // 1. Setup Sandbox
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // 2. Create File (Keep 'file' open for fchmod later)
    const filename = "test_bin";
    const file = try tmp.dir.createFile(io, filename, .{});
    defer file.close(io);

    // 3. Create Directory
    const dirname = "test_subdir";
    try tmp.dir.createDir(io, dirname, .default_dir);

    // 4. Resolve Absolute Paths
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const abs_file_len = try tmp.dir.realPathFile(
        io,
        filename,
        &path_buffer,
    );
    const abs_file_path = path_buffer[0..abs_file_len];

    var dir_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const abs_dir_len = try tmp.dir.realPathFile(
        io,
        dirname,
        &dir_buffer,
    );
    const abs_dir_path = dir_buffer[0..abs_dir_len];

    // --- TEST: doesItExist ---
    try testing.expect(doesItExist(io, abs_file_path));
    try testing.expect(!doesItExist(io, "non_existent_junk_file_123"));

    // --- TEST: isFile ---
    try testing.expect(isFile(io, abs_file_path));
    try testing.expect(!isFile(io, abs_dir_path));

    // --- TEST: isExecutable ---
    if (std.Io.File.Permissions.has_executable_bit) {
        // Case A: Make it executable (755)
        try file.setPermissions(io, .fromMode(0o755));
        try testing.expect(isExecutable(io, abs_file_path));

        // Case B: Make it non-executable (644)
        try file.setPermissions(io, .fromMode(0o644));

        // Some environments (e.g. a file system mounted with restricted
        // permission bits) silently ignore the permission change. Skip
        // instead of reporting a failure that says nothing about the code
        // under test.
        const stat = try std.Io.Dir.cwd().statFile(io, abs_file_path, .{});
        if (stat.permissions.toMode() & 0o111 != 0) return error.SkipZigTest;

        try testing.expect(!isExecutable(io, abs_file_path));
    }
}
