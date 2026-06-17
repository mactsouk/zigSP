const std = @import("std");

/// Checks if a file system entry exists at the given path.
///
/// This function attempts to access the specified path and returns:
/// - `true` if the path exists (file, directory, symlink, etc.)
/// - `false` for any error (including non-existence)
///
/// # Parameters
/// - `io`: Io instance for async filesystem access
/// - `path`: File system path to check
///
/// # Example
/// ```zig
/// const exists = canAccess(io, "myfile.txt");
/// std.debug.print("File exists: {}\n", .{exists});
/// ```
pub fn canAccess(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// Determines if a path points to a regular file.
///
/// Returns `false` for directories, symlinks, or any access errors.
///
/// # Parameters
/// - `io`: Io instance for async filesystem access
/// - `path`: Path to check
///
/// # See Also
/// - `canAccess`: For generic existence check
/// - `isExecutable`: For executable verification
pub fn isFile(io: std.Io, path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return stat.kind == .file;
}

/// Checks if a file is executable by any user (UNIX permissions).
///
/// Examines the file mode's executable bits (owner/group/others).
/// Returns `false` for non-files or inaccessible paths.
///
/// # Parameters
/// - `io`: Io instance for async filesystem access
/// - `path`: File path to check
///
pub fn isExecutable(io: std.Io, path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    const mode = stat.permissions.toMode();
    return (mode & 0o111) != 0;
}

/// UNIX `which` command implementation in Zig.
///
/// Finds the first executable instance of a command in PATH.
///
/// # Usage
/// ```sh
/// $ zig run zwhich.zig -- ls
/// /usr/bin/ls
/// ```
///
/// # Behavior
/// 1. Parses command-line argument
/// 2. Splits PATH environment variable
/// 3. Checks each directory for executable file matching command
/// 4. Prints first valid executable path found
/// 5. Exits with error if not found
///
/// # Error Handling
/// - Returns `error.FileNotFound` when command is missing
/// - Prints usage error for incorrect arguments
/// - Handles PATH lookup failures
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

        if (canAccess(io, full_path) and
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
