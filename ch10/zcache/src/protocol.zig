/// src/protocol.zig — ZEMP: Zcache Exchange Message Protocol
///
/// ═══════════════════════════════════════════════════════════════════════════
/// WIRE PROTOCOL: DESIGNING A BINARY PROTOCOL (ZEMP)
/// ═══════════════════════════════════════════════════════════════════════════
///
/// WHY A BINARY PROTOCOL OVER A TEXT PROTOCOL (e.g., RESP)?
///
/// Redis uses RESP (REdis Serialization Protocol), a human-readable text
/// format. Text protocols are easy to debug with `telnet` but have costs:
///
///   • Every integer must be ASCII-serialised and then parsed back.
///   • Field boundaries require delimiter scanning (e.g., "\r\n").
///   • Payloads cannot contain arbitrary bytes without escaping.
///
/// ZEMP uses a fixed-width binary header so the parser can always determine
/// the exact byte length of the next message without scanning for delimiters.
/// This makes the state machine simpler, faster, and robust against payloads
/// that contain newlines or null bytes.
///
/// ───────────────────────────────────────────────────────────────────────────
/// BINARY FRAME STRUCTURE
/// ───────────────────────────────────────────────────────────────────────────
///
///  Byte offset  Size   Field
///  ──────────── ────── ──────────────────────────────────────────────────────
///   0            1 B   Magic    — always 0x5A ('Z'). Catches misaligned reads.
///   1            1 B   Version  — protocol version, currently 0x01.
///   2            1 B   Type     — Command (request) or Status (response).
///   3            1 B   Flags    — reserved, must be 0x00.
///   4–7          4 B   Length   — payload byte count, big-endian u32.
///   8…           N B   Payload  — variable-length body (see below).
///
///  Total prefix size: 8 bytes (FRAME_PREFIX_LEN).
///
/// ───────────────────────────────────────────────────────────────────────────
/// REQUEST PAYLOAD ENCODING
/// ───────────────────────────────────────────────────────────────────────────
///
///  Command  Payload layout
///  ───────  ──────────────────────────────────────────────────────────────────
///  PING     (empty — 0 bytes)
///  GET      [key_len: u16 BE][key: key_len bytes]
///  DEL      [key_len: u16 BE][key: key_len bytes]
///  SET      [key_len: u16 BE][key][value_len: u32 BE][value][ttl_ms: u64 BE]
///            ttl_ms == 0 means "no expiry"
///
/// ───────────────────────────────────────────────────────────────────────────
/// RESPONSE PAYLOAD ENCODING
/// ───────────────────────────────────────────────────────────────────────────
///
///  Status      Payload layout
///  ──────────  ──────────────────────────────────────────────────────────────
///  OK (GET)    [value_len: u32 BE][value: value_len bytes]
///  OK (others) (empty)
///  NOT_FOUND   (empty)
///  ERROR       [msg_len: u16 BE][msg: UTF-8 error description]
const std = @import("std");

// ─────────────────────────────────────────────────────────────────────────────
// § 1 · Protocol Constants
// ─────────────────────────────────────────────────────────────────────────────

/// 0x5A = ASCII 'Z' for Zcache.
/// Sent as the first byte of every frame. A receiver that sees a different
/// value knows the stream is misaligned or speaking a different protocol.
pub const MAGIC: u8 = 0x5A;

pub const VERSION: u8 = 0x01;

/// Size of the fixed-length frame prefix (magic + version + type + flags + length).
pub const FRAME_PREFIX_LEN: usize = 8;

/// Maximum payload size: 64 MiB. Requests larger than this are rejected to
/// prevent memory exhaustion attacks.
pub const MAX_PAYLOAD_LEN: u32 = 64 * 1024 * 1024;

// ─────────────────────────────────────────────────────────────────────────────
// § 2 · Enumerations
// ─────────────────────────────────────────────────────────────────────────────

/// Commands sent by the client in the Type byte of a request frame.
pub const Command = enum(u8) {
    ping = 0x01,
    get = 0x02,
    set = 0x03,
    del = 0x04,
    _, // catchall: lets us pattern-match unknown values as an error case
};

/// Status codes sent by the server in the Type byte of a response frame.
pub const Status = enum(u8) {
    ok = 0x00,
    not_found = 0x01,
    err = 0x02,
    _,
};

// ─────────────────────────────────────────────────────────────────────────────
// § 3 · Frame Header
// ─────────────────────────────────────────────────────────────────────────────

/// The first 4 bytes of every frame.
/// `packed struct` guarantees a 4-byte footprint with no padding, matching
/// the on-wire layout exactly.
pub const FrameHeader = packed struct(u32) {
    magic: u8,
    version: u8,
    /// Command (in a request) or Status (in a response).
    type_byte: u8,
    flags: u8,
};

/// Parse the 8-byte frame prefix (header + length).
/// Returns the header and the declared payload length.
pub fn parsePrefix(buf: *const [FRAME_PREFIX_LEN]u8) !struct {
    header: FrameHeader,
    payload_len: u32,
} {
    const magic = buf[0];
    if (magic != MAGIC) return error.BadMagic;

    const version = buf[1];
    if (version != VERSION) return error.UnsupportedVersion;

    const header = FrameHeader{
        .magic = magic,
        .version = version,
        .type_byte = buf[2],
        .flags = buf[3],
    };

    const payload_len = std.mem.readInt(u32, buf[4..8], .big);
    if (payload_len > MAX_PAYLOAD_LEN) return error.PayloadTooLarge;

    return .{ .header = header, .payload_len = payload_len };
}

// ─────────────────────────────────────────────────────────────────────────────
// § 4 · Request Parsing
// ─────────────────────────────────────────────────────────────────────────────

/// A fully-parsed client request.
/// All slices point into the original payload buffer — no extra allocations.
/// The caller must ensure the payload buffer outlives this struct.
pub const Request = union(Command) {
    ping: void,
    get: KeyRequest,
    set: SetRequest,
    del: KeyRequest,
};

pub const KeyRequest = struct {
    key: []const u8,
};

pub const SetRequest = struct {
    key: []const u8,
    value: []const u8,
    ttl_ms: u64,
};

/// Parse a request payload into a `Request`.
/// `payload` must be the exact bytes declared by the frame's Length field.
/// Returns slices into `payload` (zero-copy).
pub fn parseRequest(command: Command, payload: []const u8) !Request {
    return switch (command) {
        .ping => .ping,
        .get => .{ .get = .{ .key = try readKey(payload, 0) } },
        .del => .{ .del = .{ .key = try readKey(payload, 0) } },
        .set => blk: {
            var pos: usize = 0;

            const key = try readKey(payload, pos);
            pos += 2 + key.len; // u16 key_len field + key bytes

            const value = try readValue(payload, pos);
            pos += 4 + value.len; // u32 value_len field + value bytes

            if (pos + 8 > payload.len) return error.PayloadTooShort;
            const ttl_ms = std.mem.readInt(u64, payload[pos..][0..8], .big);

            break :blk .{ .set = .{
                .key = key,
                .value = value,
                .ttl_ms = ttl_ms,
            } };
        },
        _ => error.UnknownCommand,
    };
}

// ─────────────────────────────────────────────────────────────────────────────
// § 5 · Response Building
// ─────────────────────────────────────────────────────────────────────────────

/// Write a complete response frame (prefix + payload) into `writer`.
///
/// This is the primary response-emission function used by the server.
/// It constructs the 8-byte prefix on the stack, then writes the payload.
pub fn writeResponse(
    writer: anytype,
    status: Status,
    payload: []const u8,
) !void {
    // Build the 8-byte prefix on the stack — no heap allocation needed.
    var prefix: [FRAME_PREFIX_LEN]u8 = undefined;
    prefix[0] = MAGIC;
    prefix[1] = VERSION;
    prefix[2] = @intFromEnum(status);
    prefix[3] = 0x00; // flags — reserved
    std.mem.writeInt(
        u32,
        prefix[4..8],
        @intCast(payload.len),
        .big,
    );

    try writer.writeAll(&prefix);
    try writer.writeAll(payload);
}

/// Encode a GET-hit response payload: [value_len: u32][value].
/// The caller is responsible for freeing the returned slice.
pub fn encodeGetPayload(
    allocator: std.mem.Allocator,
    value: []const u8,
) ![]u8 {
    const buf = try allocator.alloc(u8, 4 + value.len);
    std.mem.writeInt(u32, buf[0..4], @intCast(value.len), .big);
    @memcpy(buf[4..], value);
    return buf;
}

/// Encode an ERROR response payload: [msg_len: u16][msg].
pub fn encodeErrorPayload(allocator: std.mem.Allocator, msg: []const u8) ![]u8 {
    const safe_msg = msg[0..@min(msg.len, std.math.maxInt(u16))];
    const buf = try allocator.alloc(u8, 2 + safe_msg.len);
    std.mem.writeInt(u16, buf[0..2], @intCast(safe_msg.len), .big);
    @memcpy(buf[2..], safe_msg);
    return buf;
}

// ─────────────────────────────────────────────────────────────────────────────
// § 6 · Private Helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Read a length-prefixed key starting at `pos` in `payload`.
/// Format: [key_len: u16 BE][key bytes]
/// Returns a slice into `payload` (zero-copy).
fn readKey(payload: []const u8, pos: usize) ![]const u8 {
    if (pos + 2 > payload.len) return error.PayloadTooShort;
    const key_len = std.mem.readInt(u16, payload[pos..][0..2], .big);
    const start = pos + 2;
    if (start + key_len > payload.len) return error.PayloadTooShort;
    return payload[start .. start + key_len];
}

/// Read a length-prefixed value starting at `pos` in `payload`.
/// Format: [value_len: u32 BE][value bytes]
fn readValue(payload: []const u8, pos: usize) ![]const u8 {
    if (pos + 4 > payload.len) return error.PayloadTooShort;
    const value_len = std.mem.readInt(u32, payload[pos..][0..4], .big);
    const start = pos + 4;
    if (start + value_len > payload.len) return error.PayloadTooShort;
    return payload[start .. start + value_len];
}

// ─────────────────────────────────────────────────────────────────────────────
// § 7 · Unit Tests
// ─────────────────────────────────────────────────────────────────────────────

test "parsePrefix: valid header" {
    var buf: [FRAME_PREFIX_LEN]u8 = undefined;
    buf[0] = MAGIC;
    buf[1] = VERSION;
    buf[2] = @intFromEnum(Command.get);
    buf[3] = 0x00;
    std.mem.writeInt(u32, buf[4..8], 42, .big);

    const result = try parsePrefix(&buf);
    try std.testing.expectEqual(MAGIC, result.header.magic);
    try std.testing.expectEqual(VERSION, result.header.version);
    try std.testing.expectEqual(@as(u32, 42), result.payload_len);
}

test "parsePrefix: bad magic byte returns error" {
    var buf: [FRAME_PREFIX_LEN]u8 = [_]u8{0} ** FRAME_PREFIX_LEN;
    buf[0] = 0xFF; // wrong magic
    try std.testing.expectError(error.BadMagic, parsePrefix(&buf));
}

test "parsePrefix: payload too large returns error" {
    var buf: [FRAME_PREFIX_LEN]u8 = undefined;
    buf[0] = MAGIC;
    buf[1] = VERSION;
    buf[2] = 0x02;
    buf[3] = 0x00;
    std.mem.writeInt(u32, buf[4..8], MAX_PAYLOAD_LEN + 1, .big);
    try std.testing.expectError(error.PayloadTooLarge, parsePrefix(&buf));
}

test "parseRequest: PING" {
    const req = try parseRequest(.ping, &[_]u8{});
    try std.testing.expect(req == .ping);
}

test "parseRequest: GET" {
    // Payload: [key_len=5][hello]
    const payload = "\x00\x05hello";
    const req = try parseRequest(.get, payload);
    try std.testing.expectEqualStrings("hello", req.get.key);
}

test "parseRequest: SET with TTL" {
    // Payload: [key_len=3][key][value_len=5][value][ttl_ms=1000]
    var buf: [2 + 3 + 4 + 5 + 8]u8 = undefined;
    var pos: usize = 0;
    std.mem.writeInt(u16, buf[pos..][0..2], 3, .big);
    pos += 2;
    @memcpy(buf[pos..][0..3], "key");
    pos += 3;
    std.mem.writeInt(u32, buf[pos..][0..4], 5, .big);
    pos += 4;
    @memcpy(buf[pos..][0..5], "value");
    pos += 5;
    std.mem.writeInt(u64, buf[pos..][0..8], 1000, .big);

    const req = try parseRequest(.set, &buf);
    try std.testing.expectEqualStrings("key", req.set.key);
    try std.testing.expectEqualStrings("value", req.set.value);
    try std.testing.expectEqual(@as(u64, 1000), req.set.ttl_ms);
}

test "encodeGetPayload roundtrip" {
    const value = "zcache_value";
    const payload = try encodeGetPayload(std.testing.allocator, value);
    defer std.testing.allocator.free(payload);

    const decoded_len = std.mem.readInt(u32, payload[0..4], .big);
    try std.testing.expectEqual(@as(u32, @intCast(value.len)), decoded_len);
    try std.testing.expectEqualStrings(value, payload[4..]);
}

test "writeResponse produces correct frame bytes" {
    // In Zig 0.16, ArrayListUnmanaged.writer() was removed.
    // Use std.Io.Writer.Allocating which grows dynamically.
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeResponse(&aw.writer, .ok, "pong");

    const written = aw.writer.buffer[0..aw.writer.end];
    try std.testing.expectEqual(@as(usize, FRAME_PREFIX_LEN + 4), written.len);
    try std.testing.expectEqual(MAGIC, written[0]);
    try std.testing.expectEqual(VERSION, written[1]);
    try std.testing.expectEqual(@intFromEnum(Status.ok), written[2]);
    const len = std.mem.readInt(u32, written[4..8][0..4], .big);
    try std.testing.expectEqual(@as(u32, 4), len);
    try std.testing.expectEqualStrings("pong", written[8..]);
}
