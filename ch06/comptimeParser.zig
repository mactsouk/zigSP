//! Comptime-driven ZEMP parser.
//!
//! ZEMP (Zig Exchange Memory Protocol) is the binary framing used by the
//! memServer/memClient pair in this chapter.  The hand-written JSON encoder
//! in memServer.zig is flexible but leaves layout errors latent: a field
//! renamed, a type widened from u32 to u64, or a new field inserted in the
//! middle all produce silent parse failures at runtime.
//!
//! The comptime parser below is parameterised by the message struct type.
//! It uses @typeInfo to iterate over fields in declaration order and
//! generates byte-exact encoding/decoding for each one at compile time.
//! The benefits:
//!
//!   • Adding a field to a struct is sufficient — no parser code changes.
//!   • A field with an unsupported type (f64, bool, pointer) is a
//!     @compileError, not a runtime panic.
//!   • The total encoded size is a comptime constant, so callers can
//!     stack-allocate exactly the right buffer.
//!   • Zero runtime type dispatch: the switch over field kinds is fully
//!     unrolled by the compiler.
//!
//! Run: zig run ch06/comptimeParser.zig

const std = @import("std");

// -----------------------------------------------------------------
// Wire frame layout (all integers little-endian):
//
//   [0..1]   opcode    u16
//   [2..3]   flags     u16
//   [4..7]   seq       u32  sequence number
//   [8..N-1] payload        fixed-size, struct-derived
//
// The payload size is @sizeOf(PayloadType), computed at compile time.
// The header is always 8 bytes.
// -----------------------------------------------------------------
const HEADER_SIZE: usize = 8;

const FrameHeader = extern struct {
    opcode: u16,
    flags: u16,
    seq: u32,
};

comptime {
    if (@sizeOf(FrameHeader) != HEADER_SIZE)
        @compileError("FrameHeader must be exactly 8 bytes");
}

// Supported ZEMP opcodes
const Opcode = struct {
    const MEM_QUERY_REQ: u16 = 0x0001;
    const MEM_QUERY_RESP: u16 = 0x0002;
    const PING: u16 = 0x00FF;
};

// -----------------------------------------------------------------
// Message payload structs.
//
// Every field must be an unsigned integer or an enum backed by one.
// The comptime parser enforces this; any other type is a build error.
// All fields are little-endian on the wire.
// -----------------------------------------------------------------

/// Client asks for memory statistics.
const MemQueryReq = extern struct {
    flags: u32, // reserved, must be 0
    limit: u32, // max response bytes the client can accept
};

/// Server response: current memory statistics.
const MemQueryResp = extern struct {
    total_mb: u64,
    used_mb: u64,
    available_mb: u64,
    timestamp: i64, // Unix seconds
};

/// Connectivity check — no payload fields beyond the frame header.
const PingPayload = extern struct {
    nonce: u64,
};

// -----------------------------------------------------------------
// Comptime wire-size calculation.
//
// Returns the total frame byte count (header + payload) for a given
// payload struct type.  The result is a comptime_int, so callers can
// use it as an array length.
// -----------------------------------------------------------------
fn frameSize(comptime Payload: type) comptime_int {
    return HEADER_SIZE + @sizeOf(Payload);
}

// -----------------------------------------------------------------
// Comptime encoder.
//
// Serialises `msg` (any extern struct whose fields are integers or
// integer-backed enums) into `buf`, following the fields in
// declaration order.  Returns the number of bytes written.
//
// @typeInfo is evaluated at compile time; the resulting loop body is
// fully inlined — no runtime reflection, no vtable, no allocations.
// -----------------------------------------------------------------
fn encode(
    comptime Payload: type,
    hdr: FrameHeader,
    payload: Payload,
    buf: *[frameSize(Payload)]u8,
) void {
    // Write header (extern struct — safe direct cast)
    @memcpy(buf[0..HEADER_SIZE], std.mem.asBytes(&hdr));

    // Write each payload field in declaration order
    var offset: usize = HEADER_SIZE;
    // Zig 0.16: inline for (@typeInfo(Payload).@"struct".fields) |field|,
    // with field.type and field.name
    const info = @typeInfo(Payload).@"struct";
    inline for (info.field_names, info.field_types) |field_name, FieldT| {
        const value = @field(payload, field_name);
        const wire_value = wireInt(FieldT, value);
        const bytes = std.mem.asBytes(&wire_value);
        @memcpy(buf[offset..][0..@sizeOf(FieldT)], bytes);
        offset += @sizeOf(FieldT);
    }
}

// -----------------------------------------------------------------
// Comptime decoder.
//
// Parses the payload portion of `buf` (bytes HEADER_SIZE..end) into
// a value of type Payload.  Returns {header, payload} or an error if
// the buffer is too short or contains an unrecognised enum tag.
// -----------------------------------------------------------------
const DecodeError = error{
    BufferTooShort,
    InvalidEnumTag,
};

fn decode(
    comptime Payload: type,
    buf: []const u8,
) DecodeError!struct { hdr: FrameHeader, payload: Payload } {
    if (buf.len < frameSize(Payload)) return error.BufferTooShort;

    const hdr = std.mem.bytesToValue(
        FrameHeader,
        buf[0..HEADER_SIZE],
    );

    var payload: Payload = undefined;
    var offset: usize = HEADER_SIZE;
    // Zig 0.16: inline for (@typeInfo(Payload).@"struct".fields) |field|,
    // with field.type and field.name
    const info = @typeInfo(Payload).@"struct";
    inline for (info.field_names, info.field_types) |field_name, FieldT| {
        const raw = std.mem.bytesToValue(
            FieldT,
            buf[offset..][0..@sizeOf(FieldT)],
        );
        @field(payload, field_name) = fromWireInt(FieldT, raw);
        offset += @sizeOf(FieldT);
    }

    return .{ .hdr = hdr, .payload = payload };
}

// -----------------------------------------------------------------
// Helper: convert a struct field value to its little-endian wire form.
//
// Supports:
//   • Unsigned integers (u8 / u16 / u32 / u64)
//   • Signed integers   (i8 / i16 / i32 / i64)
//   • Enums backed by any of the above
//
// Any other type produces a @compileError at the call site — which
// means the error appears when you add the unsupported field, not
// when a test happens to exercise that code path.
// -----------------------------------------------------------------
fn wireInt(comptime T: type, value: T) T {
    return switch (@typeInfo(T)) {
        .int => std.mem.nativeToLittle(T, value),
        .@"enum" => |ei| {
            const I = ei.tag_type;
            const v = std.mem.nativeToLittle(I, @intFromEnum(value));
            return @enumFromInt(v);
        },
        else => @compileError(
            "ZEMP field type '" ++ @typeName(T) ++
                "' not supported; use integers or integer-backed enums",
        ),
    };
}

fn fromWireInt(comptime T: type, value: T) T {
    return switch (@typeInfo(T)) {
        .int => std.mem.littleToNative(T, value),
        .@"enum" => |ei| {
            const I = ei.tag_type;
            const v = std.mem.littleToNative(I, @intFromEnum(value));
            return @enumFromInt(v);
        },
        else => @compileError(
            "ZEMP field type '" ++ @typeName(T) ++ "' is not supported",
        ),
    };
}

// -----------------------------------------------------------------
// Comptime size assertions — sanity check the payload structs.
// -----------------------------------------------------------------
comptime {
    // MemQueryResp carries four 8-byte fields: must be 32 bytes.
    if (@sizeOf(MemQueryResp) != 32)
        @compileError("MemQueryResp wire size must be 32 bytes");
}

// -----------------------------------------------------------------
// Demo: encode a MemQueryResp, then decode it back and verify.
// -----------------------------------------------------------------
pub fn main(_: std.process.Init.Minimal) !void {
    // --- Encode ---------------------------------------------------
    const resp = MemQueryResp{
        .total_mb = 16384,
        .used_mb = 4200,
        .available_mb = 12184,
        .timestamp = 1_700_000_000,
    };
    const hdr_out = FrameHeader{
        .opcode = Opcode.MEM_QUERY_RESP,
        .flags = 0,
        .seq = 42,
    };

    var buf: [frameSize(MemQueryResp)]u8 = undefined;
    encode(MemQueryResp, hdr_out, resp, &buf);

    std.debug.print("Encoded {d}-byte ZEMP frame:\n", .{buf.len});
    for (buf, 0..) |b, i| {
        std.debug.print("{X:0>2}", .{b});
        if (i % 8 == 7) std.debug.print("\n", .{}) else std.debug.print(
            " ",
            .{},
        );
    }
    std.debug.print("\n", .{});

    // --- Decode ---------------------------------------------------
    const result = try decode(MemQueryResp, &buf);

    std.debug.print("Decoded frame:\n", .{});
    std.debug.print(
        "  opcode       = 0x{X:0>4}\n",
        .{result.hdr.opcode},
    );
    std.debug.print("  seq          = {d}\n", .{result.hdr.seq});
    std.debug.print(
        "  total_mb     = {d}\n",
        .{result.payload.total_mb},
    );
    std.debug.print("  used_mb      = {d}\n", .{result.payload.used_mb});
    std.debug.print(
        "  available_mb = {d}\n",
        .{result.payload.available_mb},
    );
    std.debug.print(
        "  timestamp    = {d}\n",
        .{result.payload.timestamp},
    );

    // Verify round-trip fidelity
    std.debug.assert(result.payload.total_mb == resp.total_mb);
    std.debug.assert(result.payload.used_mb == resp.used_mb);
    std.debug.assert(
        result.payload.available_mb == resp.available_mb,
    );
    std.debug.assert(result.payload.timestamp == resp.timestamp);
    std.debug.print("Round-trip OK.\n", .{});

    // --- Show compile-time sizes ----------------------------------
    std.debug.print("\nComptime frame sizes:\n", .{});
    std.debug.print(
        "  MemQueryReq  = {d} bytes\n",
        .{frameSize(MemQueryReq)},
    );
    std.debug.print(
        "  MemQueryResp = {d} bytes\n",
        .{frameSize(MemQueryResp)},
    );
    std.debug.print(
        "  PingPayload  = {d} bytes\n",
        .{frameSize(PingPayload)},
    );
}
