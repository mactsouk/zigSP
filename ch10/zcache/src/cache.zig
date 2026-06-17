/// src/cache.zig — The Zcache Storage Engine
///
/// ═══════════════════════════════════════════════════════════════════════════
/// THE DATA STRUCTURE STRATEGY: WHY WE NEED BOTH A HASH MAP AND A LINKED LIST
/// ═══════════════════════════════════════════════════════════════════════════
///
/// A correct LRU cache demands three O(1) operations:
///   1. GET  — find a value by key
///   2. SET  — insert or update a value, evicting the LRU entry if full
///   3. PROMOTE — on every GET/SET, move the touched entry to "most recently used"
///
/// No single data structure provides all three. Here is why we need two:
///
///   Hash Map alone:
///     ✓ O(1) lookup by key
///     ✗ No inherent ordering — you'd need O(n) to scan for the LRU entry
///
///   Doubly-Linked List alone:
///     ✓ O(1) insertion, O(1) removal of any node (given a pointer to it)
///     ✗ O(n) lookup — you'd have to walk the list to find a key
///
///   Hash Map + Doubly-Linked List (the LRU pattern):
///     ✓ O(1) lookup     — map gives you a *Node pointer directly
///     ✓ O(1) promote    — use that pointer to detach + reattach at head
///     ✓ O(1) eviction   — the tail pointer always points to the LRU entry
///
/// Visualised:
///
///   map: { "C" → ──┐  "B" → ──┐  "A" → ──┐ }
///                  ↓           ↓           ↓
///   HEAD (MRU) ←→ [C] ←→ [B] ←→ [A] ←→ TAIL (LRU)
///
///   GET("B")  →  detach B, prepend to head:
///   HEAD (MRU) ←→ [B] ←→ [C] ←→ [A] ←→ TAIL (LRU)
///
///   SET("D"), capacity full  →  evict tail (A), insert D:
///   HEAD (MRU) ←→ [D] ←→ [B] ←→ [C] ←→ TAIL (LRU)
const std = @import("std");

// ─────────────────────────────────────────────────────────────────────────────
// § 1 · The Doubly-Linked List Node
// ─────────────────────────────────────────────────────────────────────────────

/// One entry in the LRU list.
///
/// Memory ownership: the Cache heap-allocates each Node and its key/value
/// slices via the provided allocator. Callers never create or free Nodes —
/// the Cache manages their entire lifecycle.
pub const Node = struct {
    /// Heap-allocated copy of the cache key (owned by this Node).
    key: []const u8,
    /// Heap-allocated copy of the stored value (owned by this Node).
    value: []const u8,
    /// Absolute expiry as Unix milliseconds. `null` = immortal.
    expires_at_ms: ?i64,
    prev: ?*Node, // toward the MRU (head) end of the list
    next: ?*Node, // toward the LRU (tail) end of the list
};

// ─────────────────────────────────────────────────────────────────────────────
// § 2 · Cache Configuration
// ─────────────────────────────────────────────────────────────────────────────

pub const CacheConfig = struct {
    /// Maximum live entries. When full, the LRU entry is evicted on each SET.
    capacity: usize = 10_000,
    /// Hash-map pre-allocation hint — avoids early rehash overhead.
    initial_map_capacity: u32 = 1_024,
};

// ─────────────────────────────────────────────────────────────────────────────
// § 3 · The Hash Map Wrapper  (and the complete Cache struct)
// ─────────────────────────────────────────────────────────────────────────────

/// Thread-safe, TTL-aware LRU cache.
///
/// Expiry policy: **lazy** — TTLs are checked on access rather than via a
/// background sweep thread. This keeps the hot path deterministic and avoids
/// the complexity of a timer wheel for book-chapter clarity.
pub const Cache = struct {
    allocator: std.mem.Allocator,
    capacity: usize,
    len: usize,

    /// O(1) key → *Node lookup.
    ///
    /// The key stored in the map is a slice pointing into node.key
    /// (the same owned memory). There is no double-allocation, and
    /// StringHashMap's byte-content comparison means lookups work
    /// whether we pass node.key or an external slice with equal contents.
    map: std.StringHashMap(*Node),

    /// Access-ordered doubly-linked list.
    ///   head → most recently used  (new entries land here)
    ///   tail → least recently used  (evictions come from here)
    head: ?*Node,
    tail: ?*Node,

    /// Protects all mutable state.
    /// In Zig 0.16, std.Thread.Mutex was removed; use std.Io.Mutex instead.
    /// lock(io) and unlock(io) both require the Io handle.
    mutex: std.Io.Mutex,

    /// Runtime statistics for monitoring and debugging.
    stats: Stats,

    pub const Stats = struct {
        hits: u64 = 0,
        misses: u64 = 0,
        evictions: u64 = 0,
        expirations: u64 = 0,
    };

    // ── Lifecycle ────────────────────────────────────────────────────────────

    pub fn init(allocator: std.mem.Allocator, config: CacheConfig) !Cache {
        var map = std.StringHashMap(*Node).init(allocator);
        try map.ensureTotalCapacity(config.initial_map_capacity);
        return Cache{
            .allocator = allocator,
            .capacity = config.capacity,
            .len = 0,
            .map = map,
            .head = null,
            .tail = null,
            .mutex = .init,
            .stats = .{},
        };
    }

    /// Release every Node and the hash map. Do not use the Cache after this.
    pub fn deinit(self: *Cache) void {
        // Walk the list (not the map) so every node is visited exactly once.
        var node = self.head;
        while (node) |n| {
            const next = n.next;
            self.freeNode(n);
            node = next;
        }
        self.map.deinit();
    }

    // ── Public API ───────────────────────────────────────────────────────────

    /// Look up a value by key.
    ///
    ///   Hit  → promote node to MRU, return a fresh copy of the value.
    ///   Miss → return null.
    ///   TTL expired → lazily evict the node, return null.
    ///
    /// The returned slice is a heap copy owned by the caller, allocated with
    /// `gpa`; the caller must free it. We copy *under the lock* because the
    /// slice must NOT alias node.value: the instant the lock is released
    /// another thread can set() (which frees and replaces node.value) or
    /// delete() (which frees the node entirely), leaving any internal pointer
    /// dangling. Copying before unlocking is what makes get() thread-safe.
    pub fn get(
        self: *Cache,
        io: std.Io,
        gpa: std.mem.Allocator,
        key: []const u8,
    ) !?[]const u8 {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);

        const node = self.map.get(key) orelse {
            self.stats.misses += 1;
            return null;
        };

        // Lazy TTL check: evict on first access after expiry.
        if (isExpired(node)) {
            self.stats.expirations += 1;
            self.stats.misses += 1;
            self.removeNode(node);
            return null;
        }

        // Promote to MRU — the heart of LRU semantics.
        self.detach(node);
        self.attachHead(node);
        self.stats.hits += 1;

        // Copy the value while still holding the lock (see doc comment).
        return try gpa.dupe(u8, node.value);
    }

    /// Insert or update a key/value pair.
    ///
    ///   `ttl_ms`  time-to-live in milliseconds; 0 means no expiry.
    ///
    /// The cache copies `key` and `value` into its own heap allocations.
    /// The caller retains ownership of the slices it passes in.
    pub fn set(
        self: *Cache,
        io: std.Io,
        key: []const u8,
        value: []const u8,
        ttl_ms: u64,
    ) !void {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);

        const expiry = toExpiry(ttl_ms);

        // ── Update path: key already present ────────────────────────────────
        if (self.map.get(key)) |node| {
            // Replace value in-place — no need to reallocate the key.
            self.allocator.free(node.value);
            node.value = try self.allocator.dupe(u8, value);
            node.expires_at_ms = expiry;
            self.detach(node);
            self.attachHead(node); // update counts as a "use"
            return;
        }

        // ── Eviction path: cache is full ─────────────────────────────────────
        // Evict BEFORE allocating the new node so that an allocation failure
        // cannot leave the cache in an over-capacity state.
        if (self.len >= self.capacity) {
            if (self.tail) |lru| {
                self.stats.evictions += 1;
                self.removeNode(lru);
            }
        }

        // ── Insert path: new key ─────────────────────────────────────────────
        const node = try self.allocator.create(Node);
        errdefer self.allocator.destroy(node);

        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);

        const owned_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_value);

        node.* = .{
            .key = owned_key,
            .value = owned_value,
            .expires_at_ms = expiry,
            .prev = null,
            .next = null,
        };

        // Use node.key as the map key so the pointer remains valid for the
        // node's entire lifetime, independent of the caller's slice.
        try self.map.put(node.key, node);
        self.attachHead(node);
        self.len += 1;
    }

    /// Remove a key. Returns true if the key existed, false if it was absent.
    pub fn delete(self: *Cache, io: std.Io, key: []const u8) !bool {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);

        const node = self.map.get(key) orelse return false;
        self.removeNode(node);
        return true;
    }

    /// Current number of entries (includes not-yet-lazily-expired entries).
    pub fn count(self: *Cache, io: std.Io) !usize {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        return self.len;
    }

    // ── Private helpers ──────────────────────────────────────────────────────

    /// Remove a node from the map AND the list, then free its memory.
    fn removeNode(self: *Cache, node: *Node) void {
        _ = self.map.remove(node.key);
        self.detach(node);
        self.freeNode(node);
        self.len -= 1;
    }

    /// Free the node struct and its key/value slices.
    /// Caller must have already removed the node from the list and map.
    fn freeNode(self: *Cache, node: *Node) void {
        self.allocator.free(node.key);
        self.allocator.free(node.value);
        self.allocator.destroy(node);
    }

    fn isExpired(node: *Node) bool {
        const exp = node.expires_at_ms orelse return false;
        return currentTimeMs() > exp;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // § 4 · Doubly-Linked List Primitives
    // ─────────────────────────────────────────────────────────────────────────
    //
    // All mutations to head, tail, prev, and next are confined to these two
    // functions. Centralising them here makes invariants easy to audit.
    //
    // Invariants maintained at all times:
    //   • head.prev == null  (head has no predecessor)
    //   • tail.next == null  (tail has no successor)
    //   • For every node N in the list:
    //       N.prev != null → N.prev.next == N
    //       N.next != null → N.next.prev == N

    /// Splice `node` out of the list, leaving it "floating"
    /// (node.prev == null, node.next == null).
    ///
    ///  Before:  … ←→ [prev] ←→ [node] ←→ [next] ←→ …
    ///  After:   … ←→ [prev] ←→ [next] ←→ …          (node is floating)
    fn detach(self: *Cache, node: *Node) void {
        if (node.prev) |p| p.next = node.next // close the gap on the left
        else self.head = node.next; // node WAS head → its successor is new head

        if (node.next) |n| n.prev = node.prev // close the gap on the right
        else self.tail = node.prev; // node WAS tail → its predecessor is new tail

        node.prev = null;
        node.next = null;
    }

    /// Prepend a floating `node` at the head (MRU end).
    ///
    ///  Before:  [old_head] ←→ …
    ///  After:   [node] ←→ [old_head] ←→ …
    fn attachHead(self: *Cache, node: *Node) void {
        node.next = self.head;
        node.prev = null;
        if (self.head) |h| h.prev = node;
        self.head = node;
        if (self.tail == null) self.tail = node; // inserting into empty list
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// § 5 · Memory Management Notes
// ─────────────────────────────────────────────────────────────────────────────
//
// The Cache uses a single std.mem.Allocator for all dynamic memory:
//
//   Allocation sites:
//     • allocator.create(Node)      — one per insert
//     • allocator.dupe(u8, key)     — one per insert
//     • allocator.dupe(u8, value)   — one per insert (or update)
//
//   Deallocation sites (always paired):
//     • allocator.destroy(node)
//     • allocator.free(node.key)
//     • allocator.free(node.value)

/// Wall-clock time in milliseconds.
/// std.time.milliTimestamp() and std.posix.clock_gettime() were removed in
/// Zig 0.16. Call std.c.clock_gettime directly instead.
fn currentTimeMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return ts.sec * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

/// Convert a relative TTL duration to an absolute expiry timestamp.
///
/// Sentinel convention: `ttl_ms == 0` means "never expire" and yields a null
/// timestamp (which isExpired() treats as no expiry). Any non-zero value means
/// "expire that many milliseconds from now". There is no way to express
/// "expire immediately" — a caller wanting that would simply not insert.
fn toExpiry(ttl_ms: u64) ?i64 {
    if (ttl_ms == 0) return null; // 0 = no expiry, NOT immediate expiry
    return currentTimeMs() + @as(i64, @intCast(ttl_ms));
}

// ─────────────────────────────────────────────────────────────────────────────
// § 6 · Unit Tests
// ─────────────────────────────────────────────────────────────────────────────

test "basic set and get" {
    var t: std.Io.Threaded = .init_single_threaded;
    const io = t.io();
    var cache = try Cache.init(std.testing.allocator, .{ .capacity = 8 });
    defer cache.deinit();

    const a = std.testing.allocator;
    try cache.set(io, "hello", "world", 0);
    const hit = (try cache.get(io, a, "hello")).?;
    defer a.free(hit);
    try std.testing.expectEqualStrings("world", hit);
    try std.testing.expect(try cache.get(io, a, "missing") == null);
}

test "LRU eviction: least-recently-used entry is removed first" {
    // Insert A, B, C  → access order (MRU→LRU):  C · B · A
    // GET "A"         → promote A  → order:      A · C · B
    // SET "D"  (full) → evict tail B → order:    D · A · C
    var t: std.Io.Threaded = .init_single_threaded;
    const io = t.io();
    var cache = try Cache.init(
        std.testing.allocator,
        .{ .capacity = 3 },
    );
    defer cache.deinit();

    const a = std.testing.allocator;
    // ttl_ms = 0 means "no expiry";
    // these entries leave only via LRU eviction.
    try cache.set(io, "A", "1", 0);
    try cache.set(io, "B", "2", 0);
    try cache.set(io, "C", "3", 0);
    if (try cache.get(io, a, "A")) |v| a.free(v);
    try cache.set(io, "D", "4", 0);

    try std.testing.expect(try cache.get(io, a, "B") == null); // evicted
    inline for (.{ "A", "C", "D" }) |k| {
        const v = (try cache.get(io, a, k)).?;
        a.free(v);
    }
    try std.testing.expectEqual(
        @as(u64, 1),
        cache.stats.evictions,
    );
}

test "update in-place does not grow the cache" {
    var t: std.Io.Threaded = .init_single_threaded;
    const io = t.io();
    var cache = try Cache.init(std.testing.allocator, .{ .capacity = 2 });
    defer cache.deinit();

    const a = std.testing.allocator;
    try cache.set(io, "k", "v1", 0);
    try cache.set(io, "k", "v2", 0); // same key → update, not insert
    try std.testing.expectEqual(@as(usize, 1), try cache.count(io));
    const v = (try cache.get(io, a, "k")).?;
    defer a.free(v);
    try std.testing.expectEqualStrings("v2", v);
}

test "delete removes the entry and is idempotent" {
    var t: std.Io.Threaded = .init_single_threaded;
    const io = t.io();
    var cache = try Cache.init(std.testing.allocator, .{ .capacity = 4 });
    defer cache.deinit();

    try cache.set(io, "x", "42", 0);
    try std.testing.expect(try cache.delete(io, "x") == true);
    try std.testing.expect(try cache.get(io, std.testing.allocator, "x") == null);
    try std.testing.expect(try cache.delete(io, "x") == false); // already gone
}

test "TTL: entry is lazily evicted after expiry" {
    var t: std.Io.Threaded = .init_single_threaded;
    const io = t.io();
    var cache = try Cache.init(std.testing.allocator, .{ .capacity = 4 });
    defer cache.deinit();

    try cache.set(io, "tmp", "gone", 1); // 1 ms TTL
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(5), .awake);
    try std.testing.expect(try cache.get(io, std.testing.allocator, "tmp") == null);
    try std.testing.expectEqual(@as(u64, 1), cache.stats.expirations);
}

test "stats: hits and misses are tracked correctly" {
    var t: std.Io.Threaded = .init_single_threaded;
    const io = t.io();
    var cache = try Cache.init(std.testing.allocator, .{ .capacity = 4 });
    defer cache.deinit();

    const a = std.testing.allocator;
    try cache.set(io, "k", "v", 0);
    if (try cache.get(io, a, "k")) |v| a.free(v); // hit
    if (try cache.get(io, a, "k")) |v| a.free(v); // hit
    _ = try cache.get(io, a, "z"); // miss

    try std.testing.expectEqual(@as(u64, 2), cache.stats.hits);
    try std.testing.expectEqual(@as(u64, 1), cache.stats.misses);
}
