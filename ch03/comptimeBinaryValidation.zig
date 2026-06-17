//! Comptime binary format validation.
//!
//! When two processes exchange data over a wire, the byte layout of every
//! struct must match exactly.  A field that grows from u16 to u32, padding
//! inserted by the compiler, or a field reorder silently produces data that
//! parses as garbage — and only at runtime, when the broken message arrives.
//!
//! Zig's comptime lets us shift that discovery to compile time.  The
//! comptime block below refuses to compile if Record's layout diverges from
//! the wire spec, turning an obscure runtime mystery into a clear build error.
//!
//! Run: zig run ch03/comptimeBinaryValidation.zig

const std = @import("std");

// -----------------------------------------------------------------
// ZMP — Zig Message Protocol record header.
//
// Wire layout (12 bytes, little-endian):
//   Offset  0  magic    u16   must be 0xBEEF
//   Offset  2  version  u8    protocol version (currently 1)
//   Offset  3  kind     u8    message category (RecordKind enum)
//   Offset  4  length   u32   payload byte count that follows
//   Offset  8  crc32    u32   IEEE 802.3 CRC-32 over the payload
// -----------------------------------------------------------------
const RecordKind = enum(u8) {
    data = 0,
    ack = 1,
    err = 2,
    fin = 3,
};

// extern struct guarantees C-compatible layout: no padding between fields
// and no reordering.  Without extern, the compiler is free to insert padding
// and reorder fields for performance — neither is acceptable on the wire.
const Record = extern struct {
    magic: u16,
    version: u8,
    kind: RecordKind,
    length: u32,
    crc32: u32,
};

// -----------------------------------------------------------------
// Comptime layout assertions.
//
// These run before main() — before any binary is produced.
// Changing a field type or order triggers a @compileError, not a
// runtime panic or, worse, silent data corruption.
// -----------------------------------------------------------------
comptime {
    if (@sizeOf(Record) != 12)
        @compileError(
            "Record must be exactly 12 bytes; check for unexpected padding",
        );

    if (@offsetOf(Record, "magic") != 0) @compileError(
        "magic must be at wire offset 0",
    );
    if (@offsetOf(Record, "version") != 2) @compileError(
        "version must be at wire offset 2",
    );
    if (@offsetOf(Record, "kind") != 3) @compileError(
        "kind must be at wire offset 3",
    );
    if (@offsetOf(Record, "length") != 4) @compileError(
        "length must be at wire offset 4",
    );
    if (@offsetOf(Record, "crc32") != 8) @compileError(
        "crc32 must be at wire offset 8",
    );
}

// -----------------------------------------------------------------
// Generic layout validator.
//
// Reusable for any protocol struct; produces a compiler error that
// names both the type and the conflicting values, so it's immediately
// clear what changed and what the wire spec requires.
// -----------------------------------------------------------------
fn assertLayout(
    comptime T: type,
    comptime expected_size: comptime_int,
    comptime expected_align: comptime_int,
) void {
    if (@sizeOf(T) != expected_size) @compileError(
        @typeName(T) ++ " size mismatch: got " ++
            std.fmt.comptimePrint("{d}", .{@sizeOf(T)}) ++
            ", expected " ++
            std.fmt.comptimePrint("{d}", .{expected_size}),
    );
    if (@alignOf(T) != expected_align) @compileError(
        @typeName(T) ++ " alignment mismatch: got " ++
            std.fmt.comptimePrint("{d}", .{@alignOf(T)}) ++
            ", expected " ++
            std.fmt.comptimePrint("{d}", .{expected_align}),
    );
}

comptime {
    // u32 field forces 4-byte alignment; the whole struct is 4-byte aligned.
    assertLayout(Record, 12, 4);
}

// -----------------------------------------------------------------
// Parsing.
//
// The argument type *const [@sizeOf(Record)]u8 is self-documenting:
// the caller must supply exactly the right number of bytes.  No
// runtime bounds check is needed because the type system enforces it.
// -----------------------------------------------------------------
const MAGIC: u16 = 0xBEEF;
const VERSION: u8 = 1;

fn parseRecord(bytes: *const [@sizeOf(Record)]u8) Record {
    // bytesToValue handles alignment and endianness safely.
    return std.mem.bytesToValue(Record, bytes);
}

fn validateRecord(r: Record) !void {
    if (std.mem.littleToNative(
        u16,
        r.magic,
    ) != MAGIC) return error.BadMagic;
    if (r.version != VERSION) return error.UnsupportedVersion;
    if (std.mem.littleToNative(
        u32,
        r.length,
    ) > 0xFFFF) return error.PayloadTooLarge;
}

// -----------------------------------------------------------------
// CRC-32 (IEEE 802.3 polynomial 0xEDB88320 — same as zlib/gzip).
// -----------------------------------------------------------------
fn crc32(data: []const u8) u32 {
    var crc: u32 = 0xFFFFFFFF;
    for (data) |byte| {
        crc ^= byte;
        inline for (0..8) |_| {
            const mask: u32 = @as(u32, 0) -% (crc & 1);
            crc = (crc >> 1) ^ (0xEDB88320 & mask);
        }
    }
    return ~crc;
}

// -----------------------------------------------------------------
// Main: build a synthetic ZMP frame, parse it back, verify CRC.
// -----------------------------------------------------------------
pub fn main(_: std.process.Init.Minimal) !void {
    const payload = "hello from ZMP";
    const checksum = crc32(payload);

    // Serialise the header into a byte array.
    // std.mem.asBytes gives a *const [@sizeOf(Record)]u8 view with no copy.
    const hdr = Record{
        .magic = MAGIC,
        .version = VERSION,
        .kind = .data,
        .length = @intCast(payload.len),
        .crc32 = checksum,
    };

    var frame: [@sizeOf(Record) + payload.len]u8 = undefined;
    @memcpy(frame[0..@sizeOf(Record)], std.mem.asBytes(&hdr));
    @memcpy(frame[@sizeOf(Record)..], payload);

    // Parse and validate — array-size argument enforces correct length.
    const r = parseRecord(frame[0..@sizeOf(Record)]);
    try validateRecord(r);

    const body = frame[@sizeOf(Record)..][0..r.length];
    if (r.crc32 != crc32(body)) return error.CrcMismatch;

    std.debug.print("Record parsed and validated:\n", .{});
    std.debug.print("  magic   = 0x{X:0>4}\n", .{r.magic});
    std.debug.print("  version = {d}\n", .{r.version});
    std.debug.print("  kind    = {s}\n", .{@tagName(r.kind)});
    std.debug.print("  length  = {d}\n", .{r.length});
    std.debug.print("  crc32   = 0x{X:0>8}\n", .{r.crc32});
    std.debug.print("  payload = \"{s}\"\n", .{body});

    // Print the comptime-verified layout for reference.
    std.debug.print(
        "\nComptime-verified layout ({d} bytes):\n",
        .{@sizeOf(Record)},
    );
    std.debug.print(
        "  [+{d}] magic   ({d}B)\n",
        .{ @offsetOf(Record, "magic"), @sizeOf(u16) },
    );
    std.debug.print(
        "  [+{d}] version ({d}B)\n",
        .{ @offsetOf(Record, "version"), @sizeOf(u8) },
    );
    std.debug.print(
        "  [+{d}] kind    ({d}B)\n",
        .{ @offsetOf(Record, "kind"), @sizeOf(u8) },
    );
    std.debug.print(
        "  [+{d}] length  ({d}B)\n",
        .{ @offsetOf(Record, "length"), @sizeOf(u32) },
    );
    std.debug.print(
        "  [+{d}] crc32   ({d}B)\n",
        .{ @offsetOf(Record, "crc32"), @sizeOf(u32) },
    );
}
