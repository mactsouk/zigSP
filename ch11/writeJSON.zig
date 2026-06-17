const std = @import("std");

const Allocator = std.mem.Allocator;

const Record = struct {
    id: u32,
    event: []const u8,
    timestamp: []const u8,

    pub fn isValid(self: Record) bool {
        return isIso8601(self.timestamp);
    }

    pub fn reformat(self: Record, allocator: Allocator) !Record {
        const s = self.timestamp;
        if (s.len != 20) return error.InvalidTimestampFormat;
        const new_ts = try std.fmt.allocPrint(
            allocator,
            "{s}-{s}-{s} {s}:{s}:{s}",
            .{
                s[8..10], // day
                s[5..7], // month
                s[0..4], // year
                s[11..13], // hour
                s[14..16], // minute
                s[17..19], // second
            },
        );
        const new_event = try allocator.dupe(u8, self.event);
        return Record{
            .id = self.id,
            .event = new_event,
            .timestamp = new_ts,
        };
    }
};

fn isIso8601(s: []const u8) bool {
    if (s.len != 20) return false;
    if (s[4] != '-' or s[7] != '-' or s[10] != 'T' or
        s[13] != ':' or s[16] != ':' or s[19] != 'Z') return false;

    const digit_positions = [_]usize{ 0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18 };
    for (digit_positions) |i| {
        if (!std.ascii.isDigit(s[i])) return false;
    }

    const month = (s[5] - '0') * 10 + (s[6] - '0');
    const day = (s[8] - '0') * 10 + (s[9] - '0');
    const hour = (s[11] - '0') * 10 + (s[12] - '0');
    const minute = (s[14] - '0') * 10 + (s[15] - '0');
    const second = (s[17] - '0') * 10 + (s[18] - '0');

    return month >= 1 and month <= 12 and
        day >= 1 and day <= 31 and
        hour <= 23 and minute <= 59 and second <= 59;
}

const Counts = struct {
    valid: usize = 0,
    invalid: usize = 0,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len != 3) {
        std.debug.print(
            "Usage: {s} <input.json> <output.json>\n",
            .{args[0]},
        );
        return error.InvalidArguments;
    }

    const input_path = args[1];
    const output_path = args[2];

    var input_file = try std.Io.Dir.cwd().openFile(io, input_path, .{});
    defer input_file.close(io);

    const stat = try input_file.stat(io);
    const input_buffer = try allocator.alloc(u8, stat.size);
    defer allocator.free(input_buffer);

    _ = try input_file.readPositionalAll(io, input_buffer, 0);

    var reformatted: std.ArrayListUnmanaged(Record) = .empty;
    defer {
        for (reformatted.items) |item| {
            allocator.free(item.event);
            allocator.free(item.timestamp);
        }
        reformatted.deinit(allocator);
    }

    var counts = Counts{};

    const maybe_array = std.json.parseFromSlice(
        []std.json.Value,
        allocator,
        input_buffer,
        .{},
    ) catch null;

    if (maybe_array) |parsed_array| {
        defer parsed_array.deinit();
        for (parsed_array.value) |val| {
            try handleJsonValue(val, allocator, &reformatted, &counts);
        }
    } else {
        try processNDJSON(
            io,
            input_path,
            allocator,
            &reformatted,
            &counts,
        );
    }

    const out_file = try std.Io.Dir.cwd().createFile(io, output_path, .{});
    defer out_file.close(io);

    // Stringify into a growing buffer then write all at once.
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.print(
        "{f}",
        .{std.json.fmt(reformatted.items, .{})},
    );
    try out_file.writeStreamingAll(io, aw.writer.buffer[0..aw.writer.end]);

    std.debug.print(
        "Done.\nValid: {d}\nInvalid: {d}\nOutput file: {s}\n",
        .{ counts.valid, counts.invalid, output_path },
    );
}

fn handleJsonValue(
    val: std.json.Value,
    allocator: Allocator,
    reformatted: *std.ArrayListUnmanaged(Record),
    counts: *Counts,
) !void {
    if (std.json.parseFromValue(Record, allocator, val, .{})) |rec| {
        defer rec.deinit();
        if (rec.value.isValid()) {
            const new_rec_result = rec.value.reformat(allocator);
            if (new_rec_result) |new_rec| {
                try reformatted.append(allocator, new_rec);
                counts.valid += 1;
            } else |_| {
                counts.invalid += 1;
            }
        } else {
            counts.invalid += 1;
        }
    } else |_| {
        counts.invalid += 1;
    }
}

fn processNDJSON(
    io: std.Io,
    path: []const u8,
    allocator: Allocator,
    reformatted: *std.ArrayListUnmanaged(Record),
    counts: *Counts,
) !void {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    const stat = try file.stat(io);
    const content = try allocator.alloc(u8, stat.size);
    defer allocator.free(content);
    _ = try file.readPositionalAll(io, content, 0);

    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        var val = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            line,
            .{},
        );
        defer val.deinit();
        try handleJsonValue(
            val.value,
            allocator,
            reformatted,
            counts,
        );
    }
}

// Tests
test "isIso8601 validates ISO 8601 timestamps" {
    try std.testing.expect(isIso8601("2025-07-30T23:37:15Z"));
    try std.testing.expect(!isIso8601("invalid-date"));
    try std.testing.expect(!isIso8601(""));
    try std.testing.expect(!isIso8601("2025-07-30"));
    try std.testing.expect(!isIso8601("2025-07-30T23:37:15"));
    try std.testing.expect(!isIso8601("2025/07/30T23:37:15Z"));
    try std.testing.expect(!isIso8601("2025-07-30T23:37:15X"));
    try std.testing.expect(!isIso8601("XXXX-XX-XXTXX:XX:XXZ"));
    try std.testing.expect(!isIso8601("2025-13-30T23:37:15Z")); // month > 12
    try std.testing.expect(!isIso8601("2025-07-00T23:37:15Z")); // day = 0
    try std.testing.expect(!isIso8601("2025-07-30T24:37:15Z")); // hour > 23
    try std.testing.expect(!isIso8601("2025-07-30T23:60:15Z")); // minute > 59
    try std.testing.expect(!isIso8601("2025-07-30T23:37:60Z")); // second > 59
}

test "Record.isValid checks timestamp validity" {
    const valid_record = Record{
        .id = 16,
        .event = "login",
        .timestamp = "2025-07-30T23:37:15Z",
    };
    const invalid_record = Record{
        .id = 18,
        .event = "upload",
        .timestamp = "invalid-date",
    };

    try std.testing.expect(valid_record.isValid());
    try std.testing.expect(!invalid_record.isValid());
}

test "Record.reformat reformats valid timestamp" {
    const allocator = std.testing.allocator;
    const record = Record{
        .id = 16,
        .event = "login",
        .timestamp = "2025-07-30T23:37:15Z",
    };

    const reformatted = try record.reformat(allocator);
    defer {
        allocator.free(reformatted.event);
        allocator.free(reformatted.timestamp);
    }

    try std.testing.expectEqual(record.id, reformatted.id);
    try std.testing.expectEqualStrings(record.event, reformatted.event);
    try std.testing.expectEqualStrings("30-07-2025 23:37:15", reformatted.timestamp);

    const invalid_record = Record{
        .id = 18,
        .event = "upload",
        .timestamp = "invalid-date",
    };
    try std.testing.expectError(error.InvalidTimestampFormat, invalid_record.reformat(allocator));
}

test "handleJsonValue processes valid JSON" {
    const allocator = std.testing.allocator;
    var reformatted: std.ArrayListUnmanaged(Record) = .empty;
    defer {
        for (reformatted.items) |item| {
            allocator.free(item.event);
            allocator.free(item.timestamp);
        }
        reformatted.deinit(allocator);
    }
    var counts = Counts{};

    const json_str = "{\"id\": 16, \"event\": \"login\", \"timestamp\": \"2025-07-30T23:37:15Z\"}";
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const parsed_record = try std.json.parseFromValue(Record, allocator, parsed.value, .{});
    defer parsed_record.deinit();
    try handleJsonValue(parsed.value, allocator, &reformatted, &counts);

    try std.testing.expectEqual(1, counts.valid);
    try std.testing.expectEqual(0, counts.invalid);
    try std.testing.expectEqual(1, reformatted.items.len);
    try std.testing.expectEqual(@as(u32, 16), reformatted.items[0].id);
    try std.testing.expectEqualStrings("login", reformatted.items[0].event);
    try std.testing.expectEqualStrings("30-07-2025 23:37:15", reformatted.items[0].timestamp);
}

test "handleJsonValue handles invalid JSON" {
    const allocator = std.testing.allocator;
    var reformatted: std.ArrayListUnmanaged(Record) = .empty;
    defer reformatted.deinit(allocator);
    var counts = Counts{};

    const json_str = "{\"id\": 18, \"event\": \"upload\", \"timestamp\": \"invalid-date\"}";
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    try handleJsonValue(parsed.value, allocator, &reformatted, &counts);

    try std.testing.expectEqual(0, counts.valid);
    try std.testing.expectEqual(1, counts.invalid);
    try std.testing.expectEqual(0, reformatted.items.len);
}

test "process JSON array" {
    const allocator = std.testing.allocator;
    var t: std.Io.Threaded = .init_single_threaded;
    const io = t.io();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file_name = "test.json";
    var tmp_file = try tmp_dir.dir.createFile(io, file_name, .{});
    const json_content =
        \\[
        \\  {"id": 16, "event": "login", "timestamp": "2025-07-30T23:37:15Z"},
        \\  {"id": 17, "event": "logout", "timestamp": "2025-07-30T10:40:36Z"},
        \\  {"id": 18, "event": "upload", "timestamp": "invalid-date"},
        \\  {"id": 19, "event": "download", "timestamp": "invalid-date"},
        \\  {"id": 20, "event": "view", "timestamp": "2025-07-30T15:03:49Z"}
        \\]
    ;
    try tmp_file.writeStreamingAll(io, json_content);
    tmp_file.close(io);

    var reformatted: std.ArrayListUnmanaged(Record) = .empty;
    defer {
        for (reformatted.items) |item| {
            allocator.free(item.event);
            allocator.free(item.timestamp);
        }
        reformatted.deinit(allocator);
    }
    var counts = Counts{};

    var input_file = try tmp_dir.dir.openFile(io, file_name, .{});
    defer input_file.close(io);

    const stat = try input_file.stat(io);
    const input_buffer = try allocator.alloc(u8, stat.size);
    defer allocator.free(input_buffer);

    _ = try input_file.readPositionalAll(io, input_buffer, 0);

    const parsed_array = try std.json.parseFromSlice([]std.json.Value, allocator, input_buffer, .{});
    defer parsed_array.deinit();

    for (parsed_array.value) |val| {
        try handleJsonValue(val, allocator, &reformatted, &counts);
    }

    try std.testing.expectEqual(3, counts.valid);
    try std.testing.expectEqual(2, counts.invalid);
    try std.testing.expectEqual(3, reformatted.items.len);

    try std.testing.expectEqual(@as(u32, 16), reformatted.items[0].id);
    try std.testing.expectEqualStrings("login", reformatted.items[0].event);
    try std.testing.expectEqualStrings("30-07-2025 23:37:15", reformatted.items[0].timestamp);

    try std.testing.expectEqual(@as(u32, 17), reformatted.items[1].id);
    try std.testing.expectEqualStrings("logout", reformatted.items[1].event);
    try std.testing.expectEqualStrings("30-07-2025 10:40:36", reformatted.items[1].timestamp);

    try std.testing.expectEqual(@as(u32, 20), reformatted.items[2].id);
    try std.testing.expectEqualStrings("view", reformatted.items[2].event);
    try std.testing.expectEqualStrings("30-07-2025 15:03:49", reformatted.items[2].timestamp);
}

test "process NDJSON" {
    const allocator = std.testing.allocator;
    var t: std.Io.Threaded = .init_single_threaded;
    const io = t.io();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file_name = "test.ndjson";
    var tmp_file = try tmp_dir.dir.createFile(io, file_name, .{});
    const ndjson_content =
        \\{"id": 16, "event": "login", "timestamp": "2025-07-30T23:37:15Z"}
        \\{"id": 17, "event": "logout", "timestamp": "2025-07-30T10:40:36Z"}
        \\{"id": 18, "event": "upload", "timestamp": "invalid-date"}
        \\{"id": 19, "event": "download", "timestamp": "invalid-date"}
        \\{"id": 20, "event": "view", "timestamp": "2025-07-30T15:03:49Z"}
    ;
    try tmp_file.writeStreamingAll(io, ndjson_content);
    tmp_file.close(io);

    const tmp_file_path = try tmp_dir.dir.realPathFileAlloc(io, file_name, allocator);
    defer allocator.free(tmp_file_path);

    var reformatted: std.ArrayListUnmanaged(Record) = .empty;
    defer {
        for (reformatted.items) |item| {
            allocator.free(item.event);
            allocator.free(item.timestamp);
        }
        reformatted.deinit(allocator);
    }
    var counts = Counts{};

    try processNDJSON(io, tmp_file_path, allocator, &reformatted, &counts);

    try std.testing.expectEqual(3, counts.valid);
    try std.testing.expectEqual(2, counts.invalid);
    try std.testing.expectEqual(3, reformatted.items.len);

    try std.testing.expectEqual(@as(u32, 16), reformatted.items[0].id);
    try std.testing.expectEqualStrings("login", reformatted.items[0].event);
    try std.testing.expectEqualStrings("30-07-2025 23:37:15", reformatted.items[0].timestamp);

    try std.testing.expectEqual(@as(u32, 17), reformatted.items[1].id);
    try std.testing.expectEqualStrings("logout", reformatted.items[1].event);
    try std.testing.expectEqualStrings("30-07-2025 10:40:36", reformatted.items[1].timestamp);

    try std.testing.expectEqual(@as(u32, 20), reformatted.items[2].id);
    try std.testing.expectEqualStrings("view", reformatted.items[2].event);
    try std.testing.expectEqualStrings("30-07-2025 15:03:49", reformatted.items[2].timestamp);
}
