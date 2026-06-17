//! search.zig — Pattern matching and lazy search iterator
//!
//! Pattern semantics
//! ──────────────────
//! • If the pattern contains `*` or `?`, it is treated as a **glob** and
//!   matched against the **full path** using `*`-any-sequence / `?`-one-char.
//! • Otherwise, the pattern is a **substring** and is matched anywhere inside
//!   the full path.
//! • All matching is case-insensitive by default; pass `case_sensitive = true`
//!   to override.

const std = @import("std");

pub const Options = struct {
    case_sensitive: bool = false,
    /// When true, match only against the final component of the path.
    basename_only: bool = false,
};

// ── Glob matching ─────────────────────────────────────────────────────────────
//
// Simple recursive algorithm:
//   *  matches any sequence of characters (including the empty sequence)
//   ?  matches exactly one character
//   anything else matches itself
//
// Worst-case O(m*n) where m = len(pattern) and n = len(str); acceptable for
// typical file paths (< a few kilobytes).

fn charEq(a: u8, b: u8, case_sensitive: bool) bool {
    if (case_sensitive) return a == b;
    return std.ascii.toLower(a) == std.ascii.toLower(b);
}

pub fn globMatch(pattern: []const u8, str: []const u8, case_sensitive: bool) bool {
    // Base cases
    if (pattern.len == 0) return str.len == 0;

    if (pattern[0] == '*') {
        // Skip consecutive stars.
        var p = pattern;
        while (p.len > 0 and p[0] == '*') p = p[1..];
        if (p.len == 0) return true; // trailing * matches everything
        // Try matching * against 0, 1, 2 … characters of str.
        var s = str;
        while (true) {
            if (globMatch(p, s, case_sensitive)) return true;
            if (s.len == 0) return false;
            s = s[1..];
        }
    }

    if (str.len == 0) return false;

    if (pattern[0] == '?' or charEq(pattern[0], str[0], case_sensitive)) {
        return globMatch(pattern[1..], str[1..], case_sensitive);
    }

    return false;
}

// ── Substring matching ────────────────────────────────────────────────────────
fn substringMatch(
    needle: []const u8,
    haystack: []const u8,
    case_sensitive: bool,
) bool {
    if (case_sensitive) return std.mem.indexOf(u8, haystack, needle) != null;

    // Case-insensitive scan.
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    const limit = haystack.len - needle.len + 1;
    while (i < limit) : (i += 1) {
        var match = true;
        for (needle, 0..) |c, j| {
            if (!charEq(c, haystack[i + j], false)) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

// ── Dispatch ──────────────────────────────────────────────────────────────────
fn hasGlobChars(pattern: []const u8) bool {
    return std.mem.indexOfAny(u8, pattern, "*?") != null;
}

/// Returns true when `pattern` matches `path` under `opts`.
pub fn matches(pattern: []const u8, path: []const u8, opts: Options) bool {
    const subject: []const u8 = if (opts.basename_only)
        std.fs.path.basename(path)
    else
        path;

    if (hasGlobChars(pattern)) {
        return globMatch(pattern, subject, opts.case_sensitive);
    } else {
        return substringMatch(pattern, subject, opts.case_sensitive);
    }
}

// ── Lazy iterator ─────────────────────────────────────────────────────────────
/// Yields paths from `paths` that match `pattern` without allocating.
pub const Iterator = struct {
    paths: []const []const u8,
    pattern: []const u8,
    opts: Options,
    index: usize = 0,

    pub fn init(
        paths: []const []const u8,
        pattern: []const u8,
        opts: Options,
    ) Iterator {
        return .{ .paths = paths, .pattern = pattern, .opts = opts };
    }

    /// Return the next matching path, or null when exhausted.
    pub fn next(self: *Iterator) ?[]const u8 {
        while (self.index < self.paths.len) {
            const path = self.paths[self.index];
            self.index += 1;
            if (matches(self.pattern, path, self.opts)) return path;
        }
        return null;
    }

    /// Return the total number of remaining matches (consumes the iterator).
    pub fn count(self: *Iterator) usize {
        var n: usize = 0;
        while (self.next()) |_| n += 1;
        return n;
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────
test "glob: exact match" {
    const t = std.testing;
    try t.expect(globMatch("foo", "foo", true));
    try t.expect(!globMatch("foo", "bar", true));
}

test "glob: star wildcard" {
    const t = std.testing;
    try t.expect(globMatch("*.zig", "main.zig", true));
    try t.expect(globMatch("*.zig", "src/lib.zig", true));
    try t.expect(!globMatch("*.zig", "main.c", true));
    try t.expect(globMatch("*", "anything", true));
    try t.expect(globMatch("*", "", true));
}

test "glob: question mark" {
    const t = std.testing;
    try t.expect(globMatch("main.?ig", "main.zig", true));
    try t.expect(!globMatch("main.?ig", "main.ig", true));
}

test "glob: complex pattern" {
    const t = std.testing;
    try t.expect(globMatch("/home/*/.*rc", "/home/alice/.bashrc", true));
    try t.expect(globMatch("/home/*/.*rc", "/home/bob/.zshrc", true));
    try t.expect(!globMatch("/home/*/.*rc", "/home/alice/.config/nvim", true));
}

test "substring: case-insensitive" {
    const t = std.testing;
    try t.expect(substringMatch("Main", "/home/user/Main.zig", false));
    try t.expect(substringMatch("main", "/home/user/Main.zig", false));
    try t.expect(!substringMatch("main", "/home/user/lib.zig", false));
}

test "iterator yields only matches" {
    const t = std.testing;
    const paths = [_][]const u8{
        "/home/alice/project/main.zig",
        "/home/alice/project/build.zig",
        "/home/alice/notes.txt",
        "/etc/hosts",
    };
    var it = Iterator.init(&paths, "*.zig", .{});
    try t.expectEqualStrings("/home/alice/project/main.zig", it.next().?);
    try t.expectEqualStrings("/home/alice/project/build.zig", it.next().?);
    try t.expectEqual(@as(?[]const u8, null), it.next());
}
