const std = @import("std");
const sqlite3 = @cImport({
    @cInclude("sqlite3.h");
});

const Event = struct {
    id: i64,
    event: []const u8,
    timestamp: []const u8,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) {
        std.debug.print("Usage: {s} <db_path> <json_file>\n", .{args[0]});
        return error.InvalidArguments;
    }
    const db_path = args[1];
    const json_path = args[2];

    var db: ?*sqlite3.sqlite3 = null;
    try checkError(sqlite3.sqlite3_open(db_path, &db));
    defer {
        if (db) |db_ptr| _ = sqlite3.sqlite3_close(db_ptr);
    }
    const db_ptr = db orelse return error.MissingDatabase;
    try ensureTableExists(db_ptr, Event);

    const json_data = try readEntireFile(io, allocator, json_path);
    defer allocator.free(json_data);

    const parsed = try std.json.parseFromSlice(
        []Event,
        allocator,
        json_data,
        .{},
    );
    defer parsed.deinit();

    var valid: usize = 0;
    var rejected: usize = 0;

    for (parsed.value) |record| {
        if (try idExists(db_ptr, record.id)) {
            std.debug.print(
                "ID {d} already exists. Skipping.\n",
                .{record.id},
            );
            rejected += 1;
            continue;
        }
        try insertRecord(db_ptr, record);
        valid += 1;
    }

    std.debug.print(
        "Done.\nValid inserts: {d}\nRejected records: {d}\n",
        .{ valid, rejected },
    );
}

// Uses @typeInfo to inspect T's fields at compile time and generate the
// CREATE TABLE statement. Adding a field to T is the only change needed.
fn ensureTableExists(
    db: *sqlite3.sqlite3,
    comptime T: type,
) !void {
    const info = @typeInfo(T).@"struct";
    comptime var sql: []const u8 =
        "CREATE TABLE IF NOT EXISTS events (\n";
    inline for (info.fields, 0..) |field, i| {
        const col_type = comptime sqlType(field.type);
        const comma = if (i == 0) "" else ",\n";
        const is_id = comptime std.mem.eql(u8, field.name, "id");
        const pk: []const u8 = if (is_id) " PRIMARY KEY" else "";
        sql = sql ++ comma ++
            "  " ++ field.name ++ " " ++ col_type ++ pk;
    }
    sql = sql ++ "\n);";
    try checkError(
        sqlite3.sqlite3_exec(db, sql.ptr, null, null, null),
    );
}

// Maps a Zig type to a SQLite column type at compile time.
fn sqlType(comptime T: type) []const u8 {
    return switch (T) {
        i64, i32, c_int => "INTEGER",
        f64, f32 => "REAL",
        []const u8 => "TEXT NOT NULL",
        else => @compileError(
            "unsupported field type: " ++ @typeName(T),
        ),
    };
}

// Uses anytype so the compiler generates a specialized version for each
// struct. The inline for unrolls entirely — no runtime loop overhead.
fn insertRecord(db: *sqlite3.sqlite3, record: anytype) !void {
    const T = @TypeOf(record);
    const info = @typeInfo(T).@"struct";

    comptime var placeholders: []const u8 = "";
    inline for (info.fields, 0..) |_, i| {
        placeholders = placeholders ++ (if (i == 0) "?" else ", ?");
    }
    const sql = "INSERT INTO events VALUES (" ++ placeholders ++ ")";

    var stmt: ?*sqlite3.sqlite3_stmt = null;
    try checkError(sqlite3.sqlite3_prepare_v2(db, sql, -1, &stmt, null));
    defer if (stmt) |s| {
        _ = sqlite3.sqlite3_finalize(s);
    };

    // Inline for unrolls into a direct sequence of bind calls — one per field.
    inline for (info.fields, 0..) |field, i| {
        const col: c_int = @intCast(i + 1);
        const val = @field(record, field.name);
        try bindValue(stmt.?, col, val);
    }

    try checkError(sqlite3.sqlite3_step(stmt.?));
}

// Dispatches to the correct sqlite3_bind_* at compile time based on type.
fn bindValue(
    stmt: *sqlite3.sqlite3_stmt,
    col: c_int,
    val: anytype,
) !void {
    const T = @TypeOf(val);
    switch (T) {
        i64, i32 => try checkError(
            sqlite3.sqlite3_bind_int64(stmt, col, @intCast(val)),
        ),
        f64, f32 => try checkError(
            sqlite3.sqlite3_bind_double(stmt, col, @floatCast(val)),
        ),
        []const u8 => try checkError(sqlite3.sqlite3_bind_text(
            stmt,
            col,
            val.ptr,
            @intCast(val.len),
            null,
        )),
        else => @compileError(
            "unsupported bind type: " ++ @typeName(T),
        ),
    }
}

fn idExists(db: *sqlite3.sqlite3, id: i64) !bool {
    const sql = "SELECT 1 FROM events WHERE id = ? LIMIT 1";
    var stmt: ?*sqlite3.sqlite3_stmt = null;
    try checkError(sqlite3.sqlite3_prepare_v2(db, sql, -1, &stmt, null));
    defer if (stmt) |s| {
        _ = sqlite3.sqlite3_finalize(s);
    };
    try checkError(sqlite3.sqlite3_bind_int64(stmt.?, 1, id));
    return sqlite3.sqlite3_step(stmt.?) == sqlite3.SQLITE_ROW;
}

fn readEntireFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const buf = try allocator.alloc(u8, stat.size);
    errdefer allocator.free(buf);
    _ = try file.readPositionalAll(io, buf, 0);
    return buf;
}

fn checkError(result: c_int) !void {
    if (result != sqlite3.SQLITE_OK and
        result != sqlite3.SQLITE_DONE and
        result != sqlite3.SQLITE_ROW)
    {
        std.debug.print(
            "SQLite error ({d}): {s}\n",
            .{ result, sqlite3.sqlite3_errstr(result) },
        );
        return error.SqliteError;
    }
}
