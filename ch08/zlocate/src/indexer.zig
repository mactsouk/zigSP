//! indexer.zig — Concurrent file-system crawler
//!
//! A pool of OS threads shares a single work queue of directory paths.
//! Each worker pops a dir, iterates it, appends entries to results,
//! and re-queues sub-directories. Termination when queue empty and no
//! worker is active.

const std = @import("std");

// ── Public types ─────────────────────────────────────────────────────────────
pub const Config = struct {
    num_threads: u32 = 0,
    root_paths: []const []const u8,
    exclude: []const []const u8 = &.{},
    follow_symlinks: bool = false,
    max_depth: u32 = 0,
};

pub const Stats = struct {
    files_indexed: u64 = 0,
    dirs_traversed: u64 = 0,
    errors_skipped: u64 = 0,
    bytes_in_paths: u64 = 0,
    duration_ns: u64 = 0,
};

pub const Result = struct {
    allocator: std.mem.Allocator,
    paths: [][]u8,
    stats: Stats,

    pub fn deinit(self: *Result) void {
        for (self.paths) |p| self.allocator.free(p);
        self.allocator.free(self.paths);
    }
};

// ── Internal types ────────────────────────────────────────────────────────────
const WorkItem = struct {
    path: []u8,
    depth: u32,
};

const WorkQueue = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(WorkItem),
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    active: u32 = 0,

    fn init(allocator: std.mem.Allocator) WorkQueue {
        return .{
            .allocator = allocator,
            .items = std.ArrayList(WorkItem).empty,
        };
    }

    fn deinit(self: *WorkQueue) void {
        for (self.items.items) |item| self.allocator.free(item.path);
        self.items.deinit(self.allocator);
    }

    fn push(self: *WorkQueue, io: std.Io, path: []const u8, depth: u32) !void {
        const owned = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned);

        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        try self.items.append(self.allocator, .{ .path = owned, .depth = depth });
        self.cond.signal(io);
    }

    fn pop(self: *WorkQueue, io: std.Io) ?WorkItem {
        self.mutex.lock(io) catch return null;
        defer self.mutex.unlock(io);

        while (true) {
            if (self.items.items.len > 0) {
                self.active += 1;
                return self.items.pop();
            }
            if (self.active == 0) {
                self.cond.broadcast(io);
                return null;
            }
            self.cond.wait(io, &self.mutex) catch return null;
        }
    }

    fn finish(self: *WorkQueue, io: std.Io) void {
        self.mutex.lock(io) catch return;
        defer self.mutex.unlock(io);
        self.active -= 1;
        if (self.active == 0 and self.items.items.len == 0) {
            self.cond.broadcast(io);
        }
    }
};

const Shared = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    queue: WorkQueue,
    config: *const Config,

    results_mu: std.Io.Mutex = .init,
    results: std.ArrayList([]u8),

    n_files: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    n_dirs: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    n_errors: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    n_bytes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    fn init(io: std.Io, allocator: std.mem.Allocator, config: *const Config) Shared {
        return .{
            .io = io,
            .allocator = allocator,
            .queue = WorkQueue.init(allocator),
            .config = config,
            .results = std.ArrayList([]u8).empty,
        };
    }

    fn deinit(self: *Shared) void {
        self.queue.deinit();
        self.results.deinit(self.allocator);
    }
};

// ── Worker thread ─────────────────────────────────────────────────────────────
fn workerThread(shared: *Shared) void {
    const io = shared.io;
    while (shared.queue.pop(io)) |item| {
        defer {
            shared.allocator.free(item.path);
            shared.queue.finish(io);
        }
        crawlDirectory(shared, item.path, item.depth) catch |err| {
            std.log.debug(
                "skipping '{s}': {s}",
                .{ item.path, @errorName(err) },
            );
            _ = shared.n_errors.fetchAdd(1, .monotonic);
        };
    }
}

fn shouldExclude(name: []const u8, patterns: []const []const u8) bool {
    for (patterns) |p| if (std.mem.eql(u8, name, p)) return true;
    return false;
}

fn crawlDirectory(shared: *Shared, dir_path: []const u8, depth: u32) !void {
    const io = shared.io;
    var dir = std.Io.Dir.openDirAbsolute(
        io,
        dir_path,
        .{ .iterate = true },
    ) catch |err| switch (err) {
        error.AccessDenied,
        error.FileNotFound,
        error.NotDir,
        => return,
        else => return err,
    };
    defer dir.close(io);

    _ = shared.n_dirs.fetchAdd(1, .monotonic);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (shouldExclude(entry.name, shared.config.exclude)) continue;

        const full_path = std.fs.path.join(
            shared.allocator,
            &.{ dir_path, entry.name },
        ) catch continue;

        const appended = blk: {
            shared.results_mu.lock(io) catch break :blk false;
            defer shared.results_mu.unlock(io);
            shared.results.append(shared.allocator, full_path) catch break :blk false;
            break :blk true;
        };
        if (!appended) {
            shared.allocator.free(full_path);
            continue;
        }

        _ = shared.n_bytes.fetchAdd(full_path.len, .monotonic);

        switch (entry.kind) {
            .directory => {
                _ = shared.n_dirs.fetchAdd(1, .monotonic);
                const limit = shared.config.max_depth;
                if (limit == 0 or depth + 1 < limit) {
                    shared.queue.push(io, full_path, depth + 1) catch {};
                }
            },
            .sym_link => {
                _ = shared.n_files.fetchAdd(1, .monotonic);
                if (shared.config.follow_symlinks) {
                    if (std.Io.Dir.realPathFileAlloc(
                        std.Io.Dir.cwd(),
                        io,
                        full_path,
                        shared.allocator,
                    )) |real| {
                        defer shared.allocator.free(real);
                        const stat = std.Io.Dir.cwd().statFile(io, real, .{}) catch continue;
                        if (stat.kind == .directory) {
                            const limit = shared.config.max_depth;
                            if (limit == 0 or depth + 1 < limit) {
                                shared.queue.push(io, real, depth + 1) catch {};
                            }
                        }
                    } else |_| {}
                }
            },
            else => {
                _ = shared.n_files.fetchAdd(1, .monotonic);
            },
        }
    }
}

// ── Public entry point ────────────────────────────────────────────────────────
pub fn buildIndex(io: std.Io, allocator: std.mem.Allocator, config: Config) !Result {
    var ts_start: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts_start);

    const num_threads: usize = if (config.num_threads == 0)
        @max(1, std.Thread.getCpuCount() catch 4)
    else
        config.num_threads;

    var shared = Shared.init(io, allocator, &config);
    defer shared.deinit();

    for (config.root_paths) |root| {
        try shared.queue.push(io, root, 0);
    }

    const threads = try allocator.alloc(std.Thread, num_threads);
    defer allocator.free(threads);

    for (threads) |*t| {
        t.* = try std.Thread.spawn(.{}, workerThread, .{&shared});
    }
    for (threads) |t| t.join();

    var ts_end: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts_end);
    const duration_ns: u64 = @intCast(
        (ts_end.sec - ts_start.sec) * 1_000_000_000 +
            (ts_end.nsec - ts_start.nsec),
    );

    const paths = try shared.results.toOwnedSlice(allocator);

    return Result{
        .allocator = allocator,
        .paths = paths,
        .stats = .{
            .files_indexed = shared.n_files.load(.monotonic),
            .dirs_traversed = shared.n_dirs.load(.monotonic),
            .errors_skipped = shared.n_errors.load(.monotonic),
            .bytes_in_paths = shared.n_bytes.load(.monotonic),
            .duration_ns = duration_ns,
        },
    };
}
