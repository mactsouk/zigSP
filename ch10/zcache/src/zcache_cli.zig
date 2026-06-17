/// src/zcache_cli.zig — Subcommand-style ZEMP client for zcache
///
/// Each invocation connects, sends exactly ONE command, prints the result,
/// and exits — no REPL, no tokeniser, no loop.
///
/// Usage:
///   zcache_cli [--host H] [--port P] <command> [args...]
///
/// Commands:
///   ping
///   get  <key>
///   set  <key> <value> [ttl_ms]
///   del  <key>
///
/// Examples:
///   zig build cli -- ping
///   zig build cli -- set name Michalis 5000
///   zig build cli -- get name
///   zig build cli -- del name
const std = @import("std");

// ─────────────────────────────────────────────────────────────────────────────
// § 1 · Protocol constants  (must match protocol.zig)
// ─────────────────────────────────────────────────────────────────────────────

const MAGIC: u8 = 0x5A;
const VERSION: u8 = 0x01;
const PREFIX_LEN: usize = 8;

const CMD_PING: u8 = 0x01;
const CMD_GET: u8 = 0x02;
const CMD_SET: u8 = 0x03;
const CMD_DEL: u8 = 0x04;

const STATUS_OK: u8 = 0x00;
const STATUS_NOT_FOUND: u8 = 0x01;
const STATUS_ERROR: u8 = 0x02;

// ─────────────────────────────────────────────────────────────────────────────
// § 2 · Wire helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Read exactly buf.len bytes from the reader.
/// readSliceAll returns error.EndOfStream if the stream ends early.
fn readExact(r: anytype, buf: []u8) !void {
    try r.readSliceAll(buf);
}

fn sendFrame(w: anytype, type_byte: u8, payload: []const u8) !void {
    var prefix: [PREFIX_LEN]u8 = undefined;
    prefix[0] = MAGIC;
    prefix[1] = VERSION;
    prefix[2] = type_byte;
    prefix[3] = 0x00;
    std.mem.writeInt(u32, prefix[4..8], @intCast(payload.len), .big);
    try w.writeAll(&prefix);
    if (payload.len > 0) try w.writeAll(payload);
    try w.flush();
}

const Response = struct {
    status: u8,
    payload: []u8, // heap-allocated; caller must free
};

fn recvFrame(r: anytype, allocator: std.mem.Allocator) !Response {
    var prefix: [PREFIX_LEN]u8 = undefined;
    try readExact(r, &prefix);
    if (prefix[0] != MAGIC) return error.BadMagic;
    if (prefix[1] != VERSION) return error.UnsupportedVersion;
    const status = prefix[2];
    const payload_len = std.mem.readInt(u32, prefix[4..8], .big);
    const payload = try allocator.alloc(u8, payload_len);
    errdefer allocator.free(payload);
    if (payload_len > 0) try readExact(r, payload);
    return .{ .status = status, .payload = payload };
}

// ─────────────────────────────────────────────────────────────────────────────
// § 3 · Payload builders
// ─────────────────────────────────────────────────────────────────────────────

/// [key_len: u16][key]
fn keyPayload(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    const buf = try allocator.alloc(u8, 2 + key.len);
    std.mem.writeInt(u16, buf[0..2], @intCast(key.len), .big);
    @memcpy(buf[2..], key);
    return buf;
}

/// [key_len: u16][key][value_len: u32][value][ttl_ms: u64]
fn setPayload(
    allocator: std.mem.Allocator,
    key: []const u8,
    value: []const u8,
    ttl_ms: u64,
) ![]u8 {
    const buf = try allocator.alloc(u8, 2 + key.len + 4 + value.len + 8);
    var pos: usize = 0;
    std.mem.writeInt(u16, buf[pos..][0..2], @intCast(key.len), .big);
    pos += 2;
    @memcpy(buf[pos..][0..key.len], key);
    pos += key.len;
    std.mem.writeInt(u32, buf[pos..][0..4], @intCast(value.len), .big);
    pos += 4;
    @memcpy(buf[pos..][0..value.len], value);
    pos += value.len;
    std.mem.writeInt(u64, buf[pos..][0..8], ttl_ms, .big);
    return buf;
}

// ─────────────────────────────────────────────────────────────────────────────
// § 4 · Response printer
// ─────────────────────────────────────────────────────────────────────────────

fn printResponse(resp: Response) void {
    switch (resp.status) {
        STATUS_OK => {
            if (resp.payload.len == 0) {
                std.debug.print("OK\n", .{});
            } else if (resp.payload.len >= 4) {
                // GET hit: [value_len: u32][value]
                const vlen = std.mem.readInt(u32, resp.payload[0..4], .big);
                if (resp.payload.len >= 4 + vlen) {
                    std.debug.print("{s}\n", .{resp.payload[4 .. 4 + vlen]});
                    return;
                }
                std.debug.print("{s}\n", .{resp.payload});
            } else {
                // Short body (e.g. PONG)
                std.debug.print("{s}\n", .{resp.payload});
            }
        },
        STATUS_NOT_FOUND => std.debug.print("(nil)\n", .{}),
        STATUS_ERROR => {
            if (resp.payload.len >= 2) {
                const mlen = std.mem.readInt(u16, resp.payload[0..2], .big);
                if (resp.payload.len >= 2 + mlen) {
                    std.debug.print("(error) {s}\n", .{resp.payload[2 .. 2 + mlen]});
                    return;
                }
            }
            std.debug.print("(error)\n", .{});
        },
        else => std.debug.print("(unknown status 0x{x:0>2})\n", .{resp.status}),
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// § 5 · Usage
// ─────────────────────────────────────────────────────────────────────────────

fn usage() void {
    std.debug.print(
        \\Usage: zcache_cli [--host H] [--port P] <command> [args]
        \\
        \\Commands:
        \\  ping
        \\  get  <key>
        \\  set  <key> <value> [ttl_ms]
        \\  del  <key>
        \\
        \\Examples:
        \\  zcache_cli ping
        \\  zcache_cli set name Michalis 5000
        \\  zcache_cli get name
        \\  zcache_cli del name
        \\
    , .{});
}

// ─────────────────────────────────────────────────────────────────────────────
// § 6 · Entry point
// ─────────────────────────────────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    // ── Parse flags and collect positional args ───────────────────────────────
    var iter = init.minimal.args.iterate();
    defer iter.deinit();
    _ = iter.next(); // skip argv[0]

    var host: []const u8 = "127.0.0.1";
    var port: u16 = 7777;

    var positional = std.ArrayListUnmanaged([]const u8).empty;
    defer positional.deinit(init.gpa);

    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--host")) {
            host = iter.next() orelse {
                std.debug.print("error: --host requires a value\n", .{});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--port")) {
            const s = iter.next() orelse {
                std.debug.print("error: --port requires a value\n", .{});
                std.process.exit(1);
            };
            port = std.fmt.parseInt(u16, s, 10) catch {
                std.debug.print("error: invalid port\n", .{});
                std.process.exit(1);
            };
        } else {
            try positional.append(init.gpa, arg);
        }
    }

    if (positional.items.len == 0) {
        usage();
        return;
    }

    const subcmd = positional.items[0];
    const rest = positional.items[1..]; // args after the subcommand

    // ── Build the payload for the chosen subcommand ───────────────────────────
    const Frame = struct { type_byte: u8, payload: []u8 };

    const frame: Frame = if (std.ascii.eqlIgnoreCase(subcmd, "ping")) .{
        .type_byte = CMD_PING,
        .payload = try init.gpa.alloc(u8, 0),
    } else if (std.ascii.eqlIgnoreCase(subcmd, "get")) blk: {
        if (rest.len < 1) {
            std.debug.print("usage: get <key>\n", .{});
            std.process.exit(1);
        }
        break :blk .{ .type_byte = CMD_GET, .payload = try keyPayload(init.gpa, rest[0]) };
    } else if (std.ascii.eqlIgnoreCase(subcmd, "del")) blk: {
        if (rest.len < 1) {
            std.debug.print("usage: del <key>\n", .{});
            std.process.exit(1);
        }
        break :blk .{ .type_byte = CMD_DEL, .payload = try keyPayload(init.gpa, rest[0]) };
    } else if (std.ascii.eqlIgnoreCase(subcmd, "set")) blk: {
        if (rest.len < 2) {
            std.debug.print("usage: set <key> <value> [ttl_ms]\n", .{});
            std.process.exit(1);
        }
        const ttl: u64 = if (rest.len >= 3)
            std.fmt.parseInt(u64, rest[2], 10) catch {
                std.debug.print("error: ttl_ms must be a non-negative integer\n", .{});
                std.process.exit(1);
            }
        else
            0;
        break :blk .{ .type_byte = CMD_SET, .payload = try setPayload(init.gpa, rest[0], rest[1], ttl) };
    } else {
        std.debug.print("unknown command: {s}\n\n", .{subcmd});
        usage();
        std.process.exit(1);
    };
    defer init.gpa.free(frame.payload);

    // ── Connect → send → receive → print → exit ───────────────────────────────
    const addr = std.Io.net.IpAddress.parseIp4(host, port) catch {
        std.debug.print("error: invalid host/port\n", .{});
        std.process.exit(1);
    };
    const stream = addr.connect(init.io, .{ .mode = .stream }) catch {
        std.debug.print("Could not connect to {s}:{d} — is `zig build run` active?\n", .{ host, port });
        std.process.exit(1);
    };
    defer stream.close(init.io);

    var rbuf: [65536]u8 = undefined;
    var wbuf: [4096]u8 = undefined;
    var reader_impl = stream.reader(init.io, &rbuf);
    var writer_impl = stream.writer(init.io, &wbuf);

    try sendFrame(&writer_impl.interface, frame.type_byte, frame.payload);

    const resp = try recvFrame(&reader_impl.interface, init.gpa);
    defer init.gpa.free(resp.payload);

    printResponse(resp);
}
