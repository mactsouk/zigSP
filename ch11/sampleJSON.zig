const std = @import("std");
const json = std.json;

const Format = enum { json, ndjson };

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    if (args.len < 2) {
        std.debug.print("Usage: {s} <record_count> [format]\n", .{args[0]});
        std.debug.print("Formats: json (default), ndjson\n", .{});
        return error.MissingArgument;
    }

    const record_count = try std.fmt.parseInt(usize, args[1], 10);
    if (record_count == 0) return;

    const format = if (args.len >= 3)
        std.meta.stringToEnum(Format, args[2]) orelse Format.json
    else
        Format.json;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};
    try generateRecords(io, record_count, format, stdout);
}

fn generateRecords(
    io: std.Io,
    count: usize,
    format: Format,
    writer: anytype,
) !void {
    const events = [_][]const u8{
        "login", "logout", "upload", "download", "view",
    };
    const base_seconds: i64 = 1753920000; // 2025-07-31T00:00:00Z
    const start_offset: i64 = 8 * 3600 + 15 * 60; // 08:15:00

    if (format == .json) {
        try writer.writeAll("[\n");
    }

    for (0..count) |i| {
        if (i > 0 and format == .json) {
            try writer.writeAll(",\n");
        }

        const id = i + 1;
        const event = events[i % events.len];

        var ts_buffer: [32]u8 = undefined;
        const timestamp = if (randomBool(io))
            "invalid-date"
        else blk: {
            const rand_offset = randomIntRange(io, i64, 1, 7200);
            break :blk try formatTimestamp(
                &ts_buffer,
                base_seconds + start_offset + (@as(i64, @intCast(i)) * rand_offset),
            );
        };

        switch (format) {
            .json => try writeJsonRecord(writer, id, event, timestamp, 2),
            .ndjson => try writeNdjsonRecord(writer, id, event, timestamp),
        }
    }

    if (format == .json) {
        try writer.writeAll("\n]");
    }
}

fn randomBool(io: std.Io) bool {
    var buf: [1]u8 = undefined;
    io.random(&buf);
    return buf[0] & 1 != 0;
}

fn randomIntRange(io: std.Io, comptime T: type, lo: T, hi: T) T {
    var buf: [8]u8 = undefined;
    io.random(&buf);
    const range: u64 = @intCast(hi - lo);
    const val = std.mem.readInt(u64, &buf, .little) % range;
    return lo + @as(T, @intCast(val));
}

fn writeJsonRecord(
    writer: anytype,
    id: usize,
    event: []const u8,
    timestamp: []const u8,
    indent: usize,
) !void {
    for (0..indent) |_| try writer.writeAll(" ");
    try writer.writeAll("{\n");

    for (0..(indent + 2)) |_| try writer.writeAll(" ");
    try writer.print("\"id\": {d},\n", .{id});

    for (0..(indent + 2)) |_| try writer.writeAll(" ");
    try writer.writeAll("\"event\": ");
    try writer.print("{f}", .{json.fmt(event, .{})});
    try writer.writeAll(",\n");

    for (0..(indent + 2)) |_| try writer.writeAll(" ");
    try writer.writeAll("\"timestamp\": ");
    try writer.print("{f}", .{json.fmt(timestamp, .{})});
    try writer.writeAll("\n");

    for (0..indent) |_| try writer.writeAll(" ");
    try writer.writeAll("}");
}

fn writeNdjsonRecord(
    writer: anytype,
    id: usize,
    event: []const u8,
    timestamp: []const u8,
) !void {
    try writer.writeAll("{\"id\":");
    try writer.print("{d}", .{id});
    try writer.writeAll(",\"event\":");
    try writer.print("{f}", .{json.fmt(event, .{})});
    try writer.writeAll(",\"timestamp\":");
    try writer.print("{f}", .{json.fmt(timestamp, .{})});
    try writer.writeAll("}\n");
}

fn formatTimestamp(
    buffer: *[32]u8,
    seconds: i64,
) ![]const u8 {
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(seconds) };
    const day_seconds = epoch_seconds.getDaySeconds();
    const days_since_epoch = epoch_seconds.getEpochDay();

    const epoch_day = std.time.epoch.EpochDay{ .day = days_since_epoch.day };
    const civil_day = epoch_day.calculateYearDay();
    const year_day = civil_day.calculateMonthDay();

    const secs_in_day = day_seconds.secs;
    const hour = @divTrunc(secs_in_day, 3600);
    const minute = @divTrunc(@mod(secs_in_day, 3600), 60);
    const second = @mod(secs_in_day, 60);

    return try std.fmt.bufPrint(
        buffer,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
        .{
            civil_day.year,
            @intFromEnum(year_day.month),
            year_day.day_index,
            hour,
            minute,
            second,
        },
    );
}
