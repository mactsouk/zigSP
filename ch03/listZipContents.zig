const std = @import("std");

// ZIP file constants
const EOCD_SIGNATURE = 0x06054b50;
const CD_SIGNATURE = 0x02014b50;
const EOCD_SIZE = 22;
const CD_HEADER_SIZE = 46;

const EOCD = struct {
    signature: u32,
    disk_num: u16,
    disk_start: u16,
    num_entries_disk: u16,
    num_entries_total: u16,
    cd_size: u32,
    cd_offset: u32,
    comment_len: u16,
};

const CentralDirectoryHeader = struct {
    signature: u32,
    version_made: u16,
    version_needed: u16,
    flags: u16,
    method: u16,
    mod_time: u16,
    mod_date: u16,
    crc32: u32,
    compressed_size: u32,
    uncompressed_size: u32,
    filename_len: u16,
    extra_len: u16,
    comment_len: u16,
    disk_start: u16,
    internal_attrs: u16,
    external_attrs: u32,
    local_header_offset: u32,
};

// Verify at compile time that field sizes sum to the expected wire sizes.
comptime {
    var eocd_wire: usize = 0;
    for (std.meta.fields(EOCD)) |f| eocd_wire += @sizeOf(f.type);
    if (eocd_wire != EOCD_SIZE)
        @compileError("EOCD field sizes do not sum to EOCD_SIZE");

    var cd_wire: usize = 0;
    for (std.meta.fields(CentralDirectoryHeader)) |f| cd_wire += @sizeOf(f.type);
    if (cd_wire != CD_HEADER_SIZE)
        @compileError("CentralDirectoryHeader field sizes do not sum to CD_HEADER_SIZE");
}

fn eocdFromBytes(b: *const [EOCD_SIZE]u8) EOCD {
    return .{
        .signature = std.mem.readInt(u32, b[0..4], .little),
        .disk_num = std.mem.readInt(u16, b[4..6], .little),
        .disk_start = std.mem.readInt(u16, b[6..8], .little),
        .num_entries_disk = std.mem.readInt(u16, b[8..10], .little),
        .num_entries_total = std.mem.readInt(u16, b[10..12], .little),
        .cd_size = std.mem.readInt(u32, b[12..16], .little),
        .cd_offset = std.mem.readInt(u32, b[16..20], .little),
        .comment_len = std.mem.readInt(u16, b[20..22], .little),
    };
}

fn cdHeaderFromBytes(b: *const [CD_HEADER_SIZE]u8) CentralDirectoryHeader {
    return .{
        .signature = std.mem.readInt(u32, b[0..4], .little),
        .version_made = std.mem.readInt(u16, b[4..6], .little),
        .version_needed = std.mem.readInt(u16, b[6..8], .little),
        .flags = std.mem.readInt(u16, b[8..10], .little),
        .method = std.mem.readInt(u16, b[10..12], .little),
        .mod_time = std.mem.readInt(u16, b[12..14], .little),
        .mod_date = std.mem.readInt(u16, b[14..16], .little),
        .crc32 = std.mem.readInt(u32, b[16..20], .little),
        .compressed_size = std.mem.readInt(u32, b[20..24], .little),
        .uncompressed_size = std.mem.readInt(u32, b[24..28], .little),
        .filename_len = std.mem.readInt(u16, b[28..30], .little),
        .extra_len = std.mem.readInt(u16, b[30..32], .little),
        .comment_len = std.mem.readInt(u16, b[32..34], .little),
        .disk_start = std.mem.readInt(u16, b[34..36], .little),
        .internal_attrs = std.mem.readInt(u16, b[36..38], .little),
        .external_attrs = std.mem.readInt(u32, b[38..42], .little),
        .local_header_offset = std.mem.readInt(u32, b[42..46], .little),
    };
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) {
        std.debug.print("Usage: {s} <archive.zip>\n", .{args[0]});
        return;
    }
    const file = try std.Io.Dir.cwd().openFile(init.io, args[1], .{});
    defer file.close(init.io);
    const file_size = (try file.stat(init.io)).size;

    // 1. Smart Seek - read the last part of the file
    const search_len = @min(file_size, 65535 + EOCD_SIZE);
    const search_start_pos = file_size - search_len;
    const buffer = try allocator.alloc(u8, search_len);
    defer allocator.free(buffer);
    _ = try file.readPositionalAll(init.io, buffer, search_start_pos);

    // 2. Backward Scan for EOCD Signature
    var found_eocd: ?EOCD = null;
    if (buffer.len >= EOCD_SIZE) {
        var i: usize = buffer.len - EOCD_SIZE;
        while (true) {
            if (std.mem.readInt(
                u32,
                buffer[i..][0..4],
                .little,
            ) == EOCD_SIGNATURE) {
                found_eocd = eocdFromBytes(buffer[i..][0..EOCD_SIZE]);
                break;
            }
            if (i == 0) break;
            i -= 1;
        }
    }

    if (found_eocd) |record| {
        try listEntries(init.io, file, record);
    } else {
        std.debug.print(
            "Error: valid EOCD signature not found.\n",
            .{},
        );
    }
}

fn listEntries(io: std.Io, file: std.Io.File, eocd: EOCD) !void {
    std.debug.print(" ZIP file listing:\n--------------------\n", .{});

    var i: usize = 0;
    var offset: u64 = eocd.cd_offset;
    while (i < eocd.num_entries_total) : (i += 1) {
        var raw_header: [CD_HEADER_SIZE]u8 = undefined;
        _ = try file.readPositionalAll(io, &raw_header, offset);
        offset += CD_HEADER_SIZE;

        const header = cdHeaderFromBytes(&raw_header);
        if (header.signature != CD_SIGNATURE) break;

        var filename_buf: [256]u8 = undefined;
        const read_len = @min(header.filename_len, filename_buf.len);
        _ = try file.readPositionalAll(
            io,
            filename_buf[0..read_len],
            offset,
        );
        offset += header.filename_len +
            header.extra_len +
            header.comment_len;

        std.debug.print("{d:>9} bytes (c)  -> {s}\n", .{
            header.compressed_size,
            filename_buf[0..read_len],
        });
    }

    std.debug.print(
        "--------------------\nTotal files: {d}\n",
        .{eocd.num_entries_total},
    );
}
