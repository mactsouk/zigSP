/// src/server.zig — The Zcache Server (Zig 0.16)
///
/// ═══════════════════════════════════════════════════════════════════════════
/// ARCHITECTURE: FROM poll() TO THREAD-PER-CONNECTION
/// ═══════════════════════════════════════════════════════════════════════════
///
/// The original server used poll(2) for event-driven I/O multiplexing.
/// Zig 0.16 removes raw POSIX socket APIs (poll, recv, send, close, accept)
/// in favour of the std.Io.net abstraction. The new architecture uses
/// thread-per-connection, which pairs cleanly with the blocking Io API:
///
///   • Main thread: accepts connections in a loop via listener.accept(io).
///   • Each connection: handed off to a detached OS thread.
///   • Shared state (Cache): protected by its own Mutex — unchanged.
///
/// Thread-per-connection trades event-loop complexity for clarity.
/// For a book example the trade-off is worthwhile: each goroutine can use
/// ordinary blocking I/O without any WouldBlock bookkeeping.
///
/// ═══════════════════════════════════════════════════════════════════════════
/// TCP FRAMING — STILL A STATE MACHINE, NOW SYNCHRONOUS
/// ═══════════════════════════════════════════════════════════════════════════
///
/// TCP is a stream protocol — data may arrive in arbitrary chunks.
/// With blocking I/O we eliminate partial-read complexity: the buffered
/// reader's readAll() loops internally until the buffer is full (or EOF).
///
///   Per-connection loop:
///     1. readAll(8 bytes)  → frame prefix
///     2. Parse prefix      → get payload_len
///     3. readAll(N bytes)  → payload
///     4. Dispatch command  → build response
///     5. writeAll + flush  → send response
///     6. Repeat until EOF or error.
const std = @import("std");
const proto = @import("protocol.zig");
const Cache = @import("cache.zig").Cache;

// ─────────────────────────────────────────────────────────────────────────────
// § 1 · Configuration
// ─────────────────────────────────────────────────────────────────────────────

pub const ServerConfig = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 7777,
    /// Retained for API compatibility; threads are detached so no hard cap is
    /// enforced in this implementation.
    max_clients: usize = 512,
    /// Per-connection I/O buffer size (bytes). Used for both the buffered
    /// stream reader and the write buffer.
    read_buf_size: usize = 64 * 1024,
};

// ─────────────────────────────────────────────────────────────────────────────
// § 2 · The Server
// ─────────────────────────────────────────────────────────────────────────────

pub const Server = struct {
    allocator: std.mem.Allocator,
    config: ServerConfig,
    cache: *Cache,

    pub fn init(
        allocator: std.mem.Allocator,
        cache: *Cache,
        config: ServerConfig,
    ) !Server {
        return Server{
            .allocator = allocator,
            .config = config,
            .cache = cache,
        };
    }

    pub fn deinit(self: *Server) void {
        _ = self;
    }

    /// Bind, listen, and handle connections. Does not return unless an
    /// unrecoverable error occurs.
    pub fn run(self: *Server, io: std.Io) !void {
        const addr = try std.Io.net.IpAddress.parseIp4(
            self.config.host,
            self.config.port,
        );
        var listener = try addr.listen(io, .{});
        defer listener.deinit(io);

        std.log.info(
            "zcache listening on {s}:{d}",
            .{ self.config.host, self.config.port },
        );

        while (true) {
            const stream = listener.accept(io) catch |err| {
                std.log.warn("accept error: {s}", .{@errorName(err)});
                continue;
            };

            // Heap-allocate the context — the spawned thread owns and frees it.
            const ctx = self.allocator.create(ConnCtx) catch |err| {
                std.log.warn(
                    "connection context allocation failed: {s}",
                    .{@errorName(err)},
                );
                stream.close(io);
                continue;
            };
            ctx.* = .{
                .io = io,
                .allocator = self.allocator,
                .stream = stream,
                .cache = self.cache,
                .buf_size = self.config.read_buf_size,
            };

            const thread = std.Thread.spawn(
                .{},
                connThread,
                .{ctx},
            ) catch |err|
                {
                    std.log.warn(
                        "thread spawn failed: {s}",
                        .{@errorName(err)},
                    );
                    stream.close(io);
                    self.allocator.destroy(ctx);
                    continue;
                };
            thread.detach();
        }
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// § 3 · Per-Connection Context and Thread Entry
// ─────────────────────────────────────────────────────────────────────────────

/// State passed to each connection thread. Heap-allocated; freed on exit.
const ConnCtx = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream,
    cache: *Cache,
    buf_size: usize,
};

/// Entry point for each connection thread.
/// Owns ctx and frees it before returning.
fn connThread(ctx: *ConnCtx) void {
    defer ctx.allocator.destroy(ctx);

    const io = ctx.io;
    const stream = ctx.stream;
    defer stream.close(io);

    // Heap-allocate per-connection buffers so thread stack stays lean.
    const read_buf = ctx.allocator.alloc(u8, ctx.buf_size) catch {
        std.log.warn("failed to allocate connection read buffer", .{});
        return;
    };
    defer ctx.allocator.free(read_buf);

    const write_buf = ctx.allocator.alloc(u8, ctx.buf_size) catch {
        std.log.warn("failed to allocate connection write buffer", .{});
        return;
    };
    defer ctx.allocator.free(write_buf);

    serveClient(io, stream, ctx.cache, ctx.allocator, read_buf, write_buf) catch |err| {
        std.log.debug("connection closed: {s}", .{@errorName(err)});
    };
}

// ─────────────────────────────────────────────────────────────────────────────
// § 4 · Frame Read / Dispatch / Write Loop
// ─────────────────────────────────────────────────────────────────────────────

fn serveClient(
    io: std.Io,
    stream: std.Io.net.Stream,
    cache: *Cache,
    allocator: std.mem.Allocator,
    read_buf: []u8,
    write_buf: []u8,
) !void {
    var reader_impl = stream.reader(io, read_buf);
    var writer_impl = stream.writer(io, write_buf);
    const r = &reader_impl.interface;
    const w = &writer_impl.interface;
    defer w.flush() catch {};

    while (true) {
        // ── 1. Read the 8-byte frame prefix ──────────────────────────────────
        //
        // readAll() blocks until the buffer is full or EOF is reached.
        // n == 0 means clean EOF (client disconnected gracefully).
        // n < FRAME_PREFIX_LEN means the connection dropped mid-frame.
        // readSliceAll reads exactly FRAME_PREFIX_LEN bytes.
        // error.EndOfStream is returned on clean EOF or mid-frame disconnect;
        // both are handled by the caller (connThread) as a normal close.
        var prefix_buf: [proto.FRAME_PREFIX_LEN]u8 = undefined;
        try r.readSliceAll(&prefix_buf);

        const parsed = proto.parsePrefix(&prefix_buf) catch |err| {
            try sendError(w, allocator, @errorName(err));
            return;
        };

        // ── 2. Read the payload ───────────────────────────────────────────────
        const payload = try allocator.alloc(u8, parsed.payload_len);
        defer allocator.free(payload);

        if (parsed.payload_len > 0) {
            try r.readSliceAll(payload);
        }

        // ── 3. Dispatch the command ───────────────────────────────────────────
        const command: proto.Command = @enumFromInt(parsed.header.type_byte);
        const request = proto.parseRequest(command, payload) catch |err| {
            try sendError(w, allocator, @errorName(err));
            continue; // keep the connection alive
        };

        try handleRequest(io, request, cache, allocator, w);
    }
}

fn handleRequest(
    io: std.Io,
    request: proto.Request,
    cache: *Cache,
    allocator: std.mem.Allocator,
    w: anytype,
) !void {
    switch (request) {
        .ping => {
            try proto.writeResponse(w, .ok, "PONG");
        },
        .get => |req| {
            if (try cache.get(io, allocator, req.key)) |value| {
                defer allocator.free(value);
                const encoded = try proto.encodeGetPayload(
                    allocator,
                    value,
                );
                defer allocator.free(encoded);
                try proto.writeResponse(w, .ok, encoded);
            } else {
                try proto.writeResponse(w, .not_found, "");
            }
        },
        .set => |req| {
            try cache.set(io, req.key, req.value, req.ttl_ms);
            try proto.writeResponse(w, .ok, "");
        },
        .del => |req| {
            const deleted = try cache.delete(io, req.key);
            const status: proto.Status =
                if (deleted) .ok else .not_found;
            try proto.writeResponse(w, status, "");
        },
    }
    // Flush after every response so the client never waits in a buffer.
    try w.flush();
}

fn sendError(w: anytype, allocator: std.mem.Allocator, msg: []const u8) !void {
    const payload = try proto.encodeErrorPayload(allocator, msg);
    defer allocator.free(payload);
    try proto.writeResponse(w, .err, payload);
    try w.flush();
}
