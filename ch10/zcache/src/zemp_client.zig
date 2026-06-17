/// zemp_client.zig — A minimal ZEMP client for zcache
///
/// Mirrors the Python test client exactly, exercising every command type:
///   PING, SET, GET, DEL — with TTL, update, delete, and large-value tests.
///
/// Build standalone:
///   zig build-exe zemp_client.zig -O Debug
///
/// Or via build.zig:
///   zig build client
///
/// Run (while `zig build run` is active in another terminal):
///   ./zig-out/bin/zemp_client
///   ./zig-out/bin/zemp_client --host 127.0.0.1 --port 7777
const std = @import("std");

// ─────────────────────────────────────────────────────────────────────────────
// § 1 · Protocol constants  (must match protocol.zig)
// ─────────────────────────────────────────────────────────────────────────────

const MAGIC: u8 = 0x5A; // 'Z'
const VERSION: u8 = 0x01;
const PREFIX_LEN: usize = 8; // magic + version + type + flags + u32 length

// Command type bytes
const CMD_PING: u8 = 0x01;
const CMD_GET: u8 = 0x02;
const CMD_SET: u8 = 0x03;
const CMD_DEL: u8 = 0x04;

// Status type bytes
const STATUS_OK: u8 = 0x00;
const STATUS_NOT_FOUND: u8 = 0x01;
const STATUS_ERROR: u8 = 0x02;

// ─────────────────────────────────────────────────────────────────────────────
// § 2 · Response type
// ─────────────────────────────────────────────────────────────────────────────

const Response = struct {
    status: u8,
    /// Heap-allocated payload slice. Caller must free.
    payload: []u8,
};

// ─────────────────────────────────────────────────────────────────────────────
// § 3 · The ZEMP Client
// ─────────────────────────────────────────────────────────────────────────────

const Client = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream,

    pub fn connect(io: std.Io, allocator: std.mem.Allocator, host: []const u8, port: u16) !Client {
        const addr = try std.Io.net.IpAddress.parseIp4(host, port);
        const stream = try addr.connect(io, .{ .mode = .stream });
        return Client{ .io = io, .allocator = allocator, .stream = stream };
    }

    pub fn disconnect(self: *Client) void {
        self.stream.close(self.io);
    }

    // ── Frame builders ────────────────────────────────────────────────────────

    /// Send a PING and return the response.
    pub fn ping(self: *Client) !Response {
        try self.sendFrame(CMD_PING, &[_]u8{});
        return self.readResponse();
    }

    /// GET key → Response.  STATUS_OK payload: [value_len: u32][value].
    pub fn get(self: *Client, key: []const u8) !Response {
        var buf = std.ArrayListUnmanaged(u8).empty;
        defer buf.deinit(self.allocator);

        try writeU16(&buf, self.allocator, @intCast(key.len));
        try buf.appendSlice(self.allocator, key);

        try self.sendFrame(CMD_GET, buf.items);
        return self.readResponse();
    }

    /// SET key=value with optional TTL in milliseconds (0 = no expiry).
    pub fn set(self: *Client, key: []const u8, value: []const u8, ttl_ms: u64) !Response {
        var buf = std.ArrayListUnmanaged(u8).empty;
        defer buf.deinit(self.allocator);

        try writeU16(&buf, self.allocator, @intCast(key.len));
        try buf.appendSlice(self.allocator, key);
        try writeU32(&buf, self.allocator, @intCast(value.len));
        try buf.appendSlice(self.allocator, value);
        try writeU64(&buf, self.allocator, ttl_ms);

        try self.sendFrame(CMD_SET, buf.items);
        return self.readResponse();
    }

    /// DEL key → STATUS_OK if deleted, STATUS_NOT_FOUND if absent.
    pub fn del(self: *Client, key: []const u8) !Response {
        var buf = std.ArrayListUnmanaged(u8).empty;
        defer buf.deinit(self.allocator);

        try writeU16(&buf, self.allocator, @intCast(key.len));
        try buf.appendSlice(self.allocator, key);

        try self.sendFrame(CMD_DEL, buf.items);
        return self.readResponse();
    }

    // ── Wire I/O ─────────────────────────────────────────────────────────────

    /// Serialise and send one ZEMP frame.
    /// Creates a fresh writer per call — safe because we always flush.
    fn sendFrame(self: *Client, type_byte: u8, payload: []const u8) !void {
        var wbuf: [4096]u8 = undefined;
        var writer_impl = self.stream.writer(self.io, &wbuf);
        const w = &writer_impl.interface;

        var prefix: [PREFIX_LEN]u8 = undefined;
        prefix[0] = MAGIC;
        prefix[1] = VERSION;
        prefix[2] = type_byte;
        prefix[3] = 0x00; // flags — reserved
        std.mem.writeInt(u32, prefix[4..8], @intCast(payload.len), .big);

        try w.writeAll(&prefix);
        if (payload.len > 0) try w.writeAll(payload);
        try w.flush();
    }

    /// Read exactly one ZEMP response frame from the stream.
    /// Creates a fresh reader per call — safe because we always consume
    /// a complete response before returning.
    /// The returned Response.payload is heap-allocated; caller must free it.
    fn readResponse(self: *Client) !Response {
        // A 64 KiB read buffer handles responses with large values.
        var rbuf: [65536]u8 = undefined;
        var reader_impl = self.stream.reader(self.io, &rbuf);
        const r = &reader_impl.interface;

        // ── 1. Read the fixed-length prefix ──────────────────────────────────
        // readSliceAll reads exactly PREFIX_LEN bytes or returns error.EndOfStream.
        var prefix: [PREFIX_LEN]u8 = undefined;
        try r.readSliceAll(&prefix);

        const magic = prefix[0];
        const version = prefix[1];
        const status = prefix[2];
        // prefix[3] = flags (ignored by client)
        const payload_len = std.mem.readInt(u32, prefix[4..8], .big);

        if (magic != MAGIC) return error.BadMagic;
        if (version != VERSION) return error.UnsupportedVersion;

        // ── 2. Read the variable-length payload ───────────────────────────────
        const payload = try self.allocator.alloc(u8, payload_len);
        errdefer self.allocator.free(payload);
        if (payload_len > 0) {
            try r.readSliceAll(payload);
        }

        return Response{ .status = status, .payload = payload };
    }

    // ── Payload helpers ───────────────────────────────────────────────────────

    /// Extract the value from a successful GET response payload.
    /// Returns a slice into `resp.payload` — valid as long as payload is live.
    pub fn getValueSlice(resp: Response) ?[]const u8 {
        if (resp.status != STATUS_OK) return null;
        if (resp.payload.len < 4) return null;
        const value_len = std.mem.readInt(u32, resp.payload[0..4], .big);
        if (resp.payload.len < 4 + value_len) return null;
        return resp.payload[4 .. 4 + value_len];
    }

    /// Extract the error message from an ERROR response payload.
    pub fn getErrorSlice(resp: Response) ?[]const u8 {
        if (resp.status != STATUS_ERROR) return null;
        if (resp.payload.len < 2) return null;
        const msg_len = std.mem.readInt(u16, resp.payload[0..2], .big);
        if (resp.payload.len < 2 + msg_len) return null;
        return resp.payload[2 .. 2 + msg_len];
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// § 4 · Big-endian write helpers
// ─────────────────────────────────────────────────────────────────────────────

fn writeU16(buf: *std.ArrayListUnmanaged(u8), a: std.mem.Allocator, v: u16) !void {
    var tmp: [2]u8 = undefined;
    std.mem.writeInt(u16, &tmp, v, .big);
    try buf.appendSlice(a, &tmp);
}
fn writeU32(buf: *std.ArrayListUnmanaged(u8), a: std.mem.Allocator, v: u32) !void {
    var tmp: [4]u8 = undefined;
    std.mem.writeInt(u32, &tmp, v, .big);
    try buf.appendSlice(a, &tmp);
}
fn writeU64(buf: *std.ArrayListUnmanaged(u8), a: std.mem.Allocator, v: u64) !void {
    var tmp: [8]u8 = undefined;
    std.mem.writeInt(u64, &tmp, v, .big);
    try buf.appendSlice(a, &tmp);
}

// ─────────────────────────────────────────────────────────────────────────────
// § 5 · Test runner
// ─────────────────────────────────────────────────────────────────────────────

/// Print a response line, decoding the payload appropriately.
fn printResponse(label: []const u8, resp: Response) void {
    const status_name: []const u8 = switch (resp.status) {
        STATUS_OK => "OK",
        STATUS_NOT_FOUND => "NOT_FOUND",
        STATUS_ERROR => "ERROR",
        else => "UNKNOWN",
    };

    if (resp.status == STATUS_OK and resp.payload.len >= 4) {
        const value = Client.getValueSlice(resp) orelse resp.payload;
        std.debug.print("  {s:<22} → {s:<12} value={s}\n", .{ label, status_name, value });
    } else if (resp.status == STATUS_ERROR) {
        const msg = Client.getErrorSlice(resp) orelse resp.payload;
        std.debug.print("  {s:<22} → {s:<12} error={s}\n", .{ label, status_name, msg });
    } else {
        std.debug.print("  {s:<22} → {s}\n", .{ label, status_name });
    }
}

fn runTests(io: std.Io, allocator: std.mem.Allocator, host: []const u8, port: u16) !void {
    std.debug.print(
        "\nConnecting to zcache at {s}:{d} …\n\n",
        .{ host, port },
    );

    var client = Client.connect(io, allocator, host, port) catch |err| {
        std.debug.print("ERROR: could not connect ({s}).\n", .{@errorName(err)});
        std.debug.print("Is `zig build run` active in another terminal?\n", .{});
        return err;
    };
    defer client.disconnect();

    // Inner helper: print and free each response.
    const send = struct {
        fn call(
            _: *Client,
            a: std.mem.Allocator,
            lbl: []const u8,
            resp: Response,
        ) void {
            defer a.free(resp.payload);
            printResponse(lbl, resp);
        }
    }.call;

    // ── Basic commands ────────────────────────────────────────────────────────
    std.debug.print("── Basic commands ──────────────────────────────────────────\n", .{});
    send(&client, allocator, "PING", try client.ping());
    send(&client, allocator, "SET name=zcache", try client.set("name", "zcache", 0));
    send(&client, allocator, "SET version=1", try client.set("version", "1", 0));
    send(&client, allocator, "GET name", try client.get("name"));
    send(&client, allocator, "GET version", try client.get("version"));
    send(&client, allocator, "GET missing_key", try client.get("missing_key"));

    // ── TTL expiry ────────────────────────────────────────────────────────────
    std.debug.print("\n── TTL expiry ──────────────────────────────────────────────\n", .{});
    send(&client, allocator, "SET ttl_key (100ms)", try client.set("ttl_key", "bye soon", 100));
    send(&client, allocator, "GET ttl_key (now)", try client.get("ttl_key"));
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(150), .awake);
    send(&client, allocator, "GET ttl_key (150ms)", try client.get("ttl_key")); // → NOT_FOUND

    // ── Update & Delete ───────────────────────────────────────────────────────
    std.debug.print("\n── Update & Delete ─────────────────────────────────────────\n", .{});
    send(&client, allocator, "SET name=updated", try client.set("name", "zcache-updated", 0));
    send(&client, allocator, "GET name (updated)", try client.get("name"));
    send(&client, allocator, "DEL name", try client.del("name"));
    send(&client, allocator, "GET name (deleted)", try client.get("name"));
    send(&client, allocator, "DEL name (gone)", try client.del("name"));

    // ── Large value ───────────────────────────────────────────────────────────
    std.debug.print("\n── Large value ─────────────────────────────────────────────\n", .{});
    const big_value = try allocator.alloc(u8, 65_000);
    defer allocator.free(big_value);
    @memset(big_value, 'x');

    send(&client, allocator, "SET big (65 000 B)", try client.set("big", big_value, 0));

    const big_resp = try client.get("big");
    defer allocator.free(big_resp.payload);
    if (Client.getValueSlice(big_resp)) |value| {
        std.debug.print(
            "  {s:<22} → OK           value length={d} bytes\n",
            .{ "GET big", value.len },
        );
    }

    std.debug.print("\n✓ All tests completed.\n\n", .{});
}

// ─────────────────────────────────────────────────────────────────────────────
// § 6 · Entry point
// ─────────────────────────────────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    // ── Parse --host / --port flags ───────────────────────────────────────────
    var iter = init.minimal.args.iterate();
    defer iter.deinit();
    _ = iter.next(); // skip argv[0]

    var host: []const u8 = "127.0.0.1";
    var port: u16 = 7777;

    while (iter.next()) |flag| {
        if (std.mem.eql(u8, flag, "--host")) {
            host = iter.next() orelse {
                std.log.err("--host requires a value", .{});
                return error.BadArgs;
            };
        } else if (std.mem.eql(u8, flag, "--port")) {
            const s = iter.next() orelse {
                std.log.err("--port requires a value", .{});
                return error.BadArgs;
            };
            port = std.fmt.parseInt(u16, s, 10) catch {
                std.log.err("invalid port: {s}", .{s});
                return error.BadArgs;
            };
        }
    }

    try runTests(init.io, init.gpa, host, port);
}
