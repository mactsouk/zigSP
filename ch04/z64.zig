const std = @import("std");

const BASE64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

// Generate a reverse lookup table at compile-time (O(1) lookup)
// 0xFF represents an invalid character (like \n or space)
const DECODE_TABLE = blk: {
    // Zig 0.16: var table: [256]u8 = [_]u8{0xFF} ** 256;
    var table: [256]u8 = @splat(0xFF);
    for (BASE64_ALPHABET, 0..) |char, i| {
        table[char] = @as(u8, @intCast(i));
    }
    break :blk table;
};

pub fn main(init: std.process.Init) !void {
    const stdout = std.Io.File.stdout();
    const stdin = std.Io.File.stdin();

    // Parse Arguments
    var iter = init.minimal.args.iterate();
    defer iter.deinit();
    _ = iter.next(); // skip program name
    const cmd = iter.next();

    var decode_mode = false;
    if (cmd) |arg| {
        if (std.mem.eql(u8, arg, "-d")) {
            decode_mode = true;
        }
    }

    if (decode_mode) {
        try decode(init.io, stdin, stdout);
    } else {
        try encode(init.io, stdin, stdout);
    }
}

// --- ENCODER (3 Bytes -> 4 Chars) ---
fn encode(io: std.Io, infile: std.Io.File, outfile: std.Io.File) !void {
    var in_buf: [4096]u8 = undefined;
    var out_buf: [6000]u8 = undefined;
    var leftover_len: usize = 0;

    while (true) {
        // Read into the buffer, starting *after* any leftover bytes
        const bytes_read = infile.readStreaming(
            io,
            &.{in_buf[leftover_len..]},
        ) catch |err| blk: {
            if (err == error.EndOfStream) break :blk @as(usize, 0);
            return err;
        };
        const total_bytes = leftover_len + bytes_read;

        if (total_bytes == 0) break; // End of File

        const chunks = total_bytes / 3;
        const processable_len = chunks * 3;

        var i: usize = 0;
        var out_idx: usize = 0;

        while (i < processable_len) : (i += 3) {
            const b0 = in_buf[i];
            const b1 = in_buf[i + 1];
            const b2 = in_buf[i + 2];

            const temp: u32 = (@as(u32, b0) << 16) |
                (@as(u32, b1) << 8) |
                @as(u32, b2);

            out_buf[out_idx] = BASE64_ALPHABET[@as(usize, (temp >> 18) & 0x3F)];
            out_buf[out_idx + 1] = BASE64_ALPHABET[@as(usize, (temp >> 12) & 0x3F)];
            out_buf[out_idx + 2] = BASE64_ALPHABET[@as(usize, (temp >> 6) & 0x3F)];
            out_buf[out_idx + 3] = BASE64_ALPHABET[@as(usize, temp & 0x3F)];
            out_idx += 4;
        }

        if (out_idx > 0) {
            try outfile.writeStreamingAll(io, out_buf[0..out_idx]);
        }

        const new_leftover = total_bytes - processable_len;

        if (bytes_read == 0) {
            if (new_leftover > 0) {
                try encodeLastChunk(
                    io,
                    in_buf[processable_len..total_bytes],
                    outfile,
                );
            }
            break;
        }

        if (new_leftover > 0) {
            std.mem.copyForwards(
                u8,
                &in_buf,
                in_buf[processable_len..total_bytes],
            );
        }
        leftover_len = new_leftover;
    }
}

fn encodeLastChunk(io: std.Io, bytes: []const u8, outfile: std.Io.File) !void {
    var out_buf: [4]u8 = undefined;

    var temp: u32 = @as(u32, bytes[0]) << 16;
    if (bytes.len > 1) {
        temp |= @as(u32, bytes[1]) << 8;
    }

    out_buf[0] = BASE64_ALPHABET[@as(usize, (temp >> 18) & 0x3F)];
    out_buf[1] = BASE64_ALPHABET[@as(usize, (temp >> 12) & 0x3F)];

    if (bytes.len > 1) {
        out_buf[2] = BASE64_ALPHABET[@as(usize, (temp >> 6) & 0x3F)];
    } else {
        out_buf[2] = '=';
    }
    out_buf[3] = '=';

    try outfile.writeStreamingAll(io, &out_buf);
}

// --- DECODER (4 Chars -> 3 Bytes) ---
fn decode(io: std.Io, infile: std.Io.File, outfile: std.Io.File) !void {
    var in_buf: [4096]u8 = undefined;
    var out_buf: [4096]u8 = undefined;
    var out_len: usize = 0;

    var quad: [4]u8 = undefined;
    var quad_count: usize = 0;

    while (true) {
        const bytes_read = infile.readStreaming(
            io,
            &.{&in_buf},
        ) catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        if (bytes_read == 0) break;

        for (in_buf[0..bytes_read]) |char| {
            // 1. Handle Padding (End of Data)
            if (char == '=') {
                if (quad_count > 1) {
                    flushQuad(quad[0..quad_count], &out_buf, &out_len);
                }
                // Flush whatever is in the main output buffer and exit
                if (out_len > 0) try outfile.writeStreamingAll(
                    io,
                    out_buf[0..out_len],
                );
                return;
            }

            // 2. Lookup Value (Filter out newlines/whitespace)
            const val = DECODE_TABLE[char];
            if (val == 0xFF) continue;

            // 3. Accumulate valid 6-bit chunk
            quad[quad_count] = val;
            quad_count += 1;

            // 4. Process Full Quad (4 * 6 bits = 24 bits -> 3 bytes)
            if (quad_count == 4) {
                const temp: u32 = (@as(u32, quad[0]) << 18) |
                    (@as(u32, quad[1]) << 12) |
                    (@as(u32, quad[2]) << 6) |
                    @as(u32, quad[3]);

                out_buf[out_len] = @as(u8, @truncate(temp >> 16));
                out_buf[out_len + 1] = @as(u8, @truncate(temp >> 8));
                out_buf[out_len + 2] = @as(u8, @truncate(temp));
                out_len += 3;
                quad_count = 0;

                // Flush output buffer if full
                if (out_len >= out_buf.len - 3) {
                    try outfile.writeStreamingAll(
                        io,
                        out_buf[0..out_len],
                    );
                    out_len = 0;
                }
            }
        }
    }
    // Final flush if we hit EOF without padding
    if (quad_count > 1) {
        flushQuad(quad[0..quad_count], &out_buf, &out_len);
    }
    if (out_len > 0) try outfile.writeStreamingAll(
        io,
        out_buf[0..out_len],
    );
}

fn flushQuad(quad_slice: []const u8, out_buf: []u8, out_len: *usize) void {
    var temp: u32 = (@as(u32, quad_slice[0]) << 18) | (@as(u32, quad_slice[1]) << 12);

    if (quad_slice.len > 2) {
        temp |= (@as(u32, quad_slice[2]) << 6);
    }

    out_buf[out_len.*] = @as(u8, @truncate(temp >> 16));
    out_len.* += 1;

    if (quad_slice.len > 2) {
        out_buf[out_len.*] = @as(u8, @truncate(temp >> 8));
        out_len.* += 1;
    }
}
