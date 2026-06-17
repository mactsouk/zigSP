//! main.zig — zlocate entry point and CLI

const std = @import("std");
const indexer = @import("indexer.zig");
const database = @import("database.zig");
const search = @import("search.zig");

const dbg = std.debug.print;

const VERSION = "0.1.0";
const DEFAULT_DB_FILENAME = "files.db";
const ROOTS_FILENAME = "roots";

// stdoutWrite and stdoutPrint are thin helpers so the rest of the module
// reads cleanly without repeating std.Io.File.stdout().writeStreamingAll
// at every call site — an ergonomic choice, not an abstraction over API
// stability.
fn stdoutWrite(io: std.Io, s: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io, s);
}

fn stdoutPrint(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, fmt, args);
    try std.Io.File.stdout().writeStreamingAll(io, s);
}

// ── CLI types ─────────────────────────────────────────────────────────────────

const Command = enum { add, remove, roots, update, search, stats, help };

const Cli = struct {
    command: Command = .help,
    db_path: ?[]const u8 = null,
    path: ?[]const u8 = null,
    roots: std.ArrayList([]const u8),
    num_threads: u32 = 0,
    excludes: std.ArrayList([]const u8),
    follow_symlinks: bool = false,
    max_depth: u32 = 0,
    pattern: ?[]const u8 = null,
    case_sensitive: bool = false,
    basename_only: bool = false,
    count_only: bool = false,
};

// ── Cache-directory helpers ───────────────────────────────────────────────────

fn cacheDir(io: std.Io, allocator: std.mem.Allocator, init: std.process.Init) ![]u8 {
    const home = init.environ_map.get("HOME") orelse
        return error.HomeNotSet;
    const dir = try std.fs.path.join(
        allocator,
        &.{ home, ".cache", "zlocate" },
    );

    std.Io.Dir.cwd().createDir(io, dir, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    return dir;
}

fn defaultDbPath(io: std.Io, allocator: std.mem.Allocator, init: std.process.Init) ![]u8 {
    const dir = cacheDir(io, allocator, init) catch
        return allocator.dupe(u8, DEFAULT_DB_FILENAME);
    defer allocator.free(dir);
    return std.fs.path.join(allocator, &.{ dir, DEFAULT_DB_FILENAME });
}

fn defaultRootsPath(io: std.Io, allocator: std.mem.Allocator, init: std.process.Init) ![]u8 {
    const dir = try cacheDir(io, allocator, init);
    defer allocator.free(dir);
    return std.fs.path.join(allocator, &.{ dir, ROOTS_FILENAME });
}

// ── Roots file I/O ────────────────────────────────────────────────────────────

fn loadRoots(io: std.Io, allocator: std.mem.Allocator, roots_path: []const u8) !std.ArrayList([]u8) {
    var list = std.ArrayList([]u8).empty;
    errdefer {
        for (list.items) |p| allocator.free(p);
        list.deinit(allocator);
    }

    const file = std.Io.Dir.cwd().openFile(io, roots_path, .{}) catch |err|
        switch (err) {
            error.FileNotFound => return list,
            else => return err,
        };
    defer file.close(io);

    const stat = try file.stat(io);
    const text = try allocator.alloc(u8, stat.size);
    defer allocator.free(text);
    _ = try file.readPositionalAll(io, text, 0);

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        try list.append(allocator, try allocator.dupe(u8, trimmed));
    }
    return list;
}

fn saveRoots(
    io: std.Io,
    allocator: std.mem.Allocator,
    roots_path: []const u8,
    roots: []const []u8,
) !void {
    var content = std.ArrayList(u8).empty;
    defer content.deinit(allocator);
    for (roots) |r| {
        try content.appendSlice(allocator, r);
        try content.append(allocator, '\n');
    }

    const tmp_path = try std.fmt.allocPrint(
        allocator,
        "{s}.tmp",
        .{roots_path},
    );
    defer allocator.free(tmp_path);

    const file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{});
    try file.writeStreamingAll(io, content.items);
    file.close(io);

    try std.Io.Dir.rename(
        std.Io.Dir.cwd(),
        tmp_path,
        std.Io.Dir.cwd(),
        roots_path,
        io,
    );
}

// ── Commands ──────────────────────────────────────────────────────────────────

fn cmdAdd(io: std.Io, allocator: std.mem.Allocator, cli: Cli, init: std.process.Init) !void {
    const raw_path = cli.path orelse {
        dbg("error: 'add' requires a path argument\n", .{});
        std.process.exit(1);
    };

    const abs_z = std.Io.Dir.realPathFileAlloc(
        std.Io.Dir.cwd(),
        io,
        raw_path,
        allocator,
    ) catch |err| {
        dbg("error: cannot resolve '{s}': {s}\n", .{ raw_path, @errorName(err) });
        std.process.exit(1);
    };
    defer allocator.free(abs_z);
    const abs: []const u8 = abs_z;

    const stat = std.Io.Dir.cwd().statFile(io, abs, .{}) catch |err| {
        dbg("error: cannot stat '{s}': {s}\n", .{ abs, @errorName(err) });
        std.process.exit(1);
    };
    if (stat.kind != .directory) {
        dbg("error: '{s}' is not a directory\n", .{abs});
        std.process.exit(1);
    }

    const roots_path = try defaultRootsPath(io, allocator, init);
    defer allocator.free(roots_path);

    var existing = try loadRoots(io, allocator, roots_path);
    defer {
        for (existing.items) |p| allocator.free(p);
        existing.deinit(allocator);
    }

    for (existing.items) |p| {
        if (std.mem.eql(u8, p, abs)) {
            try stdoutPrint(io, "'{s}' is already in the index roots.\n", .{abs});
            return;
        }
    }

    try existing.append(allocator, try allocator.dupe(u8, abs));
    try saveRoots(io, allocator, roots_path, existing.items);
    try stdoutPrint(io, "Added '{s}' to index roots.\n", .{abs});
}

fn cmdRemove(io: std.Io, allocator: std.mem.Allocator, cli: Cli, init: std.process.Init) !void {
    const raw_path = cli.path orelse {
        dbg("error: 'remove' requires a path argument\n", .{});
        std.process.exit(1);
    };

    const target_z = std.Io.Dir.realPathFileAlloc(
        std.Io.Dir.cwd(),
        io,
        raw_path,
        allocator,
    ) catch try allocator.dupe(u8, raw_path);
    defer allocator.free(target_z);
    const target: []const u8 = target_z;

    const roots_path = try defaultRootsPath(io, allocator, init);
    defer allocator.free(roots_path);

    var existing = try loadRoots(io, allocator, roots_path);
    defer {
        for (existing.items) |p| allocator.free(p);
        existing.deinit(allocator);
    }

    var new_roots = std.ArrayList([]u8).empty;
    defer {
        for (new_roots.items) |p| allocator.free(p);
        new_roots.deinit(allocator);
    }

    var removed = false;
    for (existing.items) |p| {
        if (std.mem.eql(u8, p, target)) {
            removed = true;
        } else {
            try new_roots.append(allocator, try allocator.dupe(u8, p));
        }
    }

    if (!removed) {
        dbg("'{s}' was not found in the index roots.\n", .{target});
        std.process.exit(1);
    }

    try saveRoots(io, allocator, roots_path, new_roots.items);
    try stdoutPrint(io, "Removed '{s}' from index roots.\n", .{target});
}

fn cmdRoots(io: std.Io, allocator: std.mem.Allocator, init: std.process.Init) !void {
    const roots_path = try defaultRootsPath(io, allocator, init);
    defer allocator.free(roots_path);

    var roots = try loadRoots(io, allocator, roots_path);
    defer {
        for (roots.items) |p| allocator.free(p);
        roots.deinit(allocator);
    }

    if (roots.items.len == 0) {
        dbg("No roots configured. Use 'zlocate add <path>' to add one.\n", .{});
        return;
    }
    for (roots.items) |p| try stdoutPrint(io, "{s}\n", .{p});
}

fn cmdUpdate(io: std.Io, allocator: std.mem.Allocator, cli: Cli, init: std.process.Init) !void {
    var roots = std.ArrayList([]u8).empty;
    defer {
        for (roots.items) |r| allocator.free(r);
        roots.deinit(allocator);
    }

    const raw_roots: []const []const u8 = if (cli.roots.items.len > 0) blk: {
        break :blk cli.roots.items;
    } else blk: {
        const roots_path = try defaultRootsPath(io, allocator, init);
        defer allocator.free(roots_path);
        var from_file = try loadRoots(io, allocator, roots_path);
        for (from_file.items) |p| try roots.append(allocator, p);
        from_file.items.len = 0;
        from_file.deinit(allocator);
        if (roots.items.len == 0) {
            const db_path2 = if (cli.db_path) |p|
                try allocator.dupe(u8, p)
            else
                try defaultDbPath(io, allocator, init);
            defer allocator.free(db_path2);
            try database.save(io, db_path2, &.{}, unixNow());
            try stdoutPrint(io,
                "No roots configured — saved empty index to {s}\n",
                .{db_path2},
            );
            return;
        }
        break :blk &.{};
    };

    for (raw_roots) |raw| {
        const abs_z = std.Io.Dir.realPathFileAlloc(
            std.Io.Dir.cwd(),
            io,
            raw,
            allocator,
        ) catch |err| {
            dbg("warning: cannot resolve '{s}': {s}\n", .{ raw, @errorName(err) });
            continue;
        };
        try roots.append(allocator, abs_z);
    }

    if (roots.items.len == 0) {
        dbg("error: no valid root paths\n", .{});
        std.process.exit(1);
    }

    const db_path = if (cli.db_path) |p|
        try allocator.dupe(u8, p)
    else
        try defaultDbPath(io, allocator, init);
    defer allocator.free(db_path);

    const detected = std.Thread.getCpuCount() catch 4;
    const effective = if (cli.num_threads == 0) detected else cli.num_threads;
    dbg("Indexing {d} root(s) with {d} thread(s) …\n", .{ roots.items.len, effective });
    for (roots.items) |r| dbg("  {s}\n", .{r});

    var result = try indexer.buildIndex(io, allocator, .{
        .num_threads = cli.num_threads,
        .root_paths = roots.items,
        .exclude = cli.excludes.items,
        .follow_symlinks = cli.follow_symlinks,
        .max_depth = cli.max_depth,
    });
    defer result.deinit();

    const secs = @as(f64, @floatFromInt(result.stats.duration_ns)) / 1e9;
    dbg("Crawled {d} dirs, found {d} entries in {d:.2}s\n", .{
        result.stats.dirs_traversed, result.paths.len, secs,
    });
    if (result.stats.errors_skipped > 0)
        dbg("Skipped {d} unreadable entries\n", .{result.stats.errors_skipped});

    try database.save(io, db_path, result.paths, unixNow());
    try stdoutPrint(io, "Saved {d} entries → {s}\n", .{ result.paths.len, db_path });
}

fn cmdSearch(io: std.Io, allocator: std.mem.Allocator, cli: Cli, init: std.process.Init) !void {
    const pattern = cli.pattern orelse {
        dbg("error: 'search' requires a pattern argument\n", .{});
        std.process.exit(1);
    };

    const db_path = if (cli.db_path) |p|
        try allocator.dupe(u8, p)
    else
        try defaultDbPath(io, allocator, init);
    defer allocator.free(db_path);

    var db = database.load(io, allocator, db_path) catch |err| {
        dbg("error: cannot load '{s}': {s}\n", .{ db_path, @errorName(err) });
        dbg("Run 'zlocate update' to build the index first.\n", .{});
        std.process.exit(1);
    };
    defer db.deinit(allocator);

    var it = search.Iterator.init(db.paths, pattern, .{
        .case_sensitive = cli.case_sensitive,
        .basename_only = cli.basename_only,
    });

    if (cli.count_only) {
        try stdoutPrint(io, "{d}\n", .{it.count()});
    } else {
        var line_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
        var n: u64 = 0;
        while (it.next()) |path| {
            n += 1;
            const line = try std.fmt.bufPrint(&line_buf, "{s}\n", .{path});
            try std.Io.File.stdout().writeStreamingAll(io, line);
        }
        dbg("{d} match(es)\n", .{n});
    }
}

fn cmdStats(io: std.Io, allocator: std.mem.Allocator, cli: Cli, init: std.process.Init) !void {
    const db_path = if (cli.db_path) |p|
        try allocator.dupe(u8, p)
    else
        try defaultDbPath(io, allocator, init);
    defer allocator.free(db_path);

    var db = database.load(io, allocator, db_path) catch |err| {
        dbg("error: cannot load '{s}': {s}\n", .{ db_path, @errorName(err) });
        std.process.exit(1);
    };
    defer db.deinit(allocator);

    const roots_path = try defaultRootsPath(io, allocator, init);
    defer allocator.free(roots_path);
    var roots = try loadRoots(io, allocator, roots_path);
    defer {
        for (roots.items) |p| allocator.free(p);
        roots.deinit(allocator);
    }

    const age = unixNow() - db.timestamp;

    const file = std.Io.Dir.cwd().openFile(io, db_path, .{}) catch null;
    const db_size: u64 = if (file) |f| blk: {
        defer f.close(io);
        const st = f.stat(io) catch break :blk 0;
        break :blk st.size;
    } else 0;

    try stdoutPrint(io, "Database path : {s}\n", .{db_path});
    try stdoutPrint(io, "Entries       : {d}\n", .{db.paths.len});
    try stdoutPrint(io, "File size     : {d} bytes\n", .{db_size});
    try stdoutPrint(io, "Index age     : {d}h {d}m\n", .{
        @divFloor(age, 3600), @divFloor(@mod(age, 3600), 60),
    });
    try stdoutPrint(io, "Indexed at    : {d} (Unix)\n", .{db.timestamp});

    if (roots.items.len > 0) {
        try stdoutWrite(io, "Roots         :\n");
        for (roots.items) |r| try stdoutPrint(io, "  {s}\n", .{r});
    } else {
        try stdoutWrite(io, "Roots         : (none configured)\n");
    }
}

fn printUsage(io: std.Io) !void {
    try stdoutWrite(io,
        "zlocate v" ++ VERSION ++ " — Concurrent File Indexer\n" ++
            "\n" ++
            "ROOT MANAGEMENT\n" ++
            "  zlocate add <path>      Add a directory to the index roots\n" ++
            "  zlocate remove <path>   Remove a directory from the index roots\n" ++
            "  zlocate roots           List the configured roots\n" ++
            "\n" ++
            "INDEXING\n" ++
            "  zlocate update [options]\n" ++
            "    --threads N           Worker threads (default: CPU count)\n" ++
            "    --exclude NAME        Skip entries with this basename\n" ++
            "    --follow-symlinks     Resolve and follow symbolic links\n" ++
            "    --max-depth N         Limit recursion depth (0 = unlimited)\n" ++
            "    --db PATH             Override the database file path\n" ++
            "    --root PATH           Override roots for this run only\n" ++
            "\n" ++
            "SEARCH\n" ++
            "  zlocate search [options] <pattern>\n" ++
            "    --case-sensitive      Enable case-sensitive matching\n" ++
            "    --basename            Match only against the final path component\n" ++
            "    --count               Print only the match count\n" ++
            "    --db PATH             Override the database file path\n" ++
            "\n" ++
            "STATS\n" ++
            "  zlocate stats [--db PATH]\n",
    );
}

// ── Argument parser ───────────────────────────────────────────────────────────

fn parseCli(allocator: std.mem.Allocator, argv: []const []const u8) !Cli {
    var cli = Cli{
        .roots = std.ArrayList([]const u8).empty,
        .excludes = std.ArrayList([]const u8).empty,
    };
    if (argv.len < 2) return cli;

    cli.command = std.meta.stringToEnum(Command, argv[1]) orelse {
        dbg("error: unknown command '{s}'\n", .{argv[1]});
        std.process.exit(1);
    };

    var i: usize = 2;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--root")) {
            i += 1;
            if (i >= argv.len) fatal("--root requires a value");
            try cli.roots.append(allocator, argv[i]);
        } else if (std.mem.eql(u8, arg, "--threads")) {
            i += 1;
            if (i >= argv.len) fatal("--threads requires a value");
            cli.num_threads = std.fmt.parseInt(u32, argv[i], 10) catch fatal("--threads: not a number");
        } else if (std.mem.eql(u8, arg, "--exclude")) {
            i += 1;
            if (i >= argv.len) fatal("--exclude requires a value");
            try cli.excludes.append(allocator, argv[i]);
        } else if (std.mem.eql(u8, arg, "--db")) {
            i += 1;
            if (i >= argv.len) fatal("--db requires a value");
            cli.db_path = argv[i];
        } else if (std.mem.eql(u8, arg, "--follow-symlinks")) {
            cli.follow_symlinks = true;
        } else if (std.mem.eql(u8, arg, "--max-depth")) {
            i += 1;
            if (i >= argv.len) fatal("--max-depth requires a value");
            cli.max_depth = std.fmt.parseInt(u32, argv[i], 10) catch fatal("--max-depth: not a number");
        } else if (std.mem.eql(u8, arg, "--case-sensitive")) {
            cli.case_sensitive = true;
        } else if (std.mem.eql(u8, arg, "--basename")) {
            cli.basename_only = true;
        } else if (std.mem.eql(u8, arg, "--count")) {
            cli.count_only = true;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            fatal("unknown option");
        } else {
            cli.path = arg;
            cli.pattern = arg;
        }
    }
    return cli;
}

fn fatal(msg: []const u8) noreturn {
    dbg("error: {s}\n", .{msg});
    std.process.exit(1);
}

fn unixNow() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return ts.sec;
}

// ── Entry point ───────────────────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = init.io;

    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    var cli = try parseCli(allocator, argv);
    defer cli.roots.deinit(allocator);
    defer cli.excludes.deinit(allocator);

    switch (cli.command) {
        .add => try cmdAdd(io, allocator, cli, init),
        .remove => try cmdRemove(io, allocator, cli, init),
        .roots => try cmdRoots(io, allocator, init),
        .update => try cmdUpdate(io, allocator, cli, init),
        .search => try cmdSearch(io, allocator, cli, init),
        .stats => try cmdStats(io, allocator, cli, init),
        .help => try printUsage(io),
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test {
    _ = @import("search.zig");
    _ = @import("database.zig");
}
