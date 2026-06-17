const std = @import("std");

pub fn canAccess(io: std.Io, path: []const u8) bool {
    var found: bool = true;
    std.Io.Dir.cwd().access(io, path, .{}) catch |e| switch (e) {
        error.FileNotFound => found = false,
        else => found = false,
    };
    return found;
}

pub fn isFile(io: std.Io, path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return stat.kind == .file;
}

pub fn isExecutable(io: std.Io, path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    const mode = stat.permissions.toMode();
    return (mode & 0o111) != 0;
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 2) {
        std.debug.print("Usage: {s} <command>\n", .{args[0]});
        return;
    }
    const command = args[1];

    const path_env = init.environ_map.get("PATH") orelse {
        std.debug.print("Error: PATH environment variable not set\n", .{});
        return error.MissingEnvironment;
    };

    const stdout = std.Io.File.stdout();

    var dirs = std.mem.splitScalar(u8, path_env, ':');
    var found = false;

    while (dirs.next()) |dir| {
        var pathBuf = std.ArrayList(u8).empty;
        defer pathBuf.deinit(init.gpa);
        try pathBuf.appendSlice(init.gpa, dir);
        try pathBuf.append(init.gpa, '/');
        try pathBuf.appendSlice(init.gpa, command);
        const fullPath = pathBuf.items;

        if (canAccess(init.io, fullPath) and
            isFile(init.io, fullPath) and
            isExecutable(init.io, fullPath))
        {
            try stdout.writeStreamingAll(init.io, fullPath);
            try stdout.writeStreamingAll(init.io, "\n");
            found = true;
            break;
        }
    }

    if (!found) {
        std.log.err("Command '{s}' not found in PATH", .{command});
        return error.FileNotFound;
    }
}
