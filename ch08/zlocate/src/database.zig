//! database.zig — Binary database for the file index
//!
//! File format (little-endian throughout)
//! ────────────────────────────────────────
//!   Offset  Size  Description
//!   ──────  ────  ─────────────────────────────────────────────────
//!    0       4    Magic bytes: "ZLOC"
//!    4       4    Format version (u32)
//!    8       8    Creation timestamp  (i64, Unix seconds)
//!   16       8    Number of path entries (u64)
//!   24       …    Path entries, each:
//!                   2 bytes – path length  (u16, max 65 535 bytes)
//!                   N bytes – UTF-8 path string

const std = @import("std");

pub const MAGIC = "ZLOC";
pub const VERSION: u32 = 1;

pub const Database = struct {
    timestamp: i64,
    paths: [][]const u8,

    pub fn deinit(self: *Database, allocator: std.mem.Allocator) void {
        for (self.paths) |p| allocator.free(p);
        allocator.free(self.paths);
    }
};

// ── Write ─────────────────────────────────────────────────────────────────────

pub fn save(io: std.Io, db_path: []const u8, paths: []const []u8, timestamp: i64) !void {
    var total: usize = 24;
    for (paths) |p| {
        if (p.len <= std.math.maxInt(u16)) total += 2 + p.len;
    }

    const buf = try std.heap.page_allocator.alloc(u8, total);
    defer std.heap.page_allocator.free(buf);

    var pos: usize = 0;

    @memcpy(buf[pos..][0..4], MAGIC);
    pos += 4;

    std.mem.writeInt(u32, buf[pos..][0..4], VERSION, .little);
    pos += 4;

    std.mem.writeInt(i64, buf[pos..][0..8], timestamp, .little);
    pos += 8;

    var count: u64 = 0;
    for (paths) |p| if (p.len <= std.math.maxInt(u16)) {
        count += 1;
    };
    std.mem.writeInt(u64, buf[pos..][0..8], count, .little);
    pos += 8;

    for (paths) |p| {
        if (p.len > std.math.maxInt(u16)) continue;
        std.mem.writeInt(u16, buf[pos..][0..2], @intCast(p.len), .little);
        pos += 2;
        @memcpy(buf[pos..][0..p.len], p);
        pos += p.len;
    }

    std.debug.assert(pos == total);

    const tmp_path = try std.fmt.allocPrint(
        std.heap.page_allocator,
        "{s}.tmp",
        .{db_path},
    );
    defer std.heap.page_allocator.free(tmp_path);

    const file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{});
    try file.writeStreamingAll(io, buf);
    file.close(io);

    try std.Io.Dir.rename(
        std.Io.Dir.cwd(),
        tmp_path,
        std.Io.Dir.cwd(),
        db_path,
        io,
    );
}

// ── Read ──────────────────────────────────────────────────────────────────────

pub fn load(io: std.Io, allocator: std.mem.Allocator, db_path: []const u8) anyerror!Database {
    const file = try std.Io.Dir.cwd().openFile(io, db_path, .{});
    defer file.close(io);

    const stat = try file.stat(io);
    const data = try allocator.alloc(u8, stat.size);
    defer allocator.free(data);
    _ = try file.readPositionalAll(io, data, 0);

    var pos: usize = 0;

    const need = struct {
        fn f(d: []const u8, p: *usize, n: usize) error{UnexpectedEof}![]const u8 {
            if (p.* + n > d.len) return error.UnexpectedEof;
            const s = d[p.*..][0..n];
            p.* += n;
            return s;
        }
    }.f;

    const magic = try need(data, &pos, 4);
    if (!std.mem.eql(u8, magic, MAGIC)) return error.InvalidMagic;

    const ver = std.mem.readInt(u32, (try need(data, &pos, 4))[0..4], .little);
    if (ver != VERSION) return error.UnsupportedVersion;

    const timestamp = std.mem.readInt(i64, (try need(data, &pos, 8))[0..8], .little);

    const count = std.mem.readInt(u64, (try need(data, &pos, 8))[0..8], .little);
    if (count > 500_000_000) return error.FileTooLarge;

    const paths = try allocator.alloc([]const u8, count);
    errdefer {
        for (paths) |p| allocator.free(p);
        allocator.free(paths);
    }

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const len_bytes = try need(data, &pos, 2);
        const len = std.mem.readInt(u16, len_bytes[0..2], .little);
        const path_bytes = try need(data, &pos, len);
        paths[i] = try allocator.dupe(u8, path_bytes);
    }

    return Database{ .timestamp = timestamp, .paths = paths };
}

// ── Tests ─────────────────────────────────────────────────────────────────────
test "round-trip save/load" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var t: std.Io.Threaded = .init_single_threaded;
    const io = t.io();

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir_path_z = try std.Io.Dir.realPathFileAlloc(tmp_dir.dir, io, ".", alloc);
    const db_path = try std.fs.path.join(alloc, &.{ dir_path_z, "test.db" });

    const paths_in = [_][]u8{
        try alloc.dupe(u8, "/home/user/file.txt"),
        try alloc.dupe(u8, "/etc/hosts"),
        try alloc.dupe(u8, "/usr/bin/zig"),
    };

    try save(io, db_path, &paths_in, 12345);
    var db = try load(io, alloc, db_path);
    defer db.deinit(alloc);

    try testing.expectEqual(@as(i64, 12345), db.timestamp);
    try testing.expectEqual(paths_in.len, db.paths.len);
    for (paths_in, db.paths) |expected, got| {
        try testing.expectEqualStrings(expected, got);
    }
}
