const std = @import("std");
const sqlite3 = @cImport({
    @cInclude("sqlite3.h");
});

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    _ = allocator;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len != 5) {
        std.debug.print(
            "Usage: {s} <db_path> <name> <email> <age>\n",
            .{args[0]},
        );
        return error.InvalidArgument;
    }

    const db_path = args[1];
    const name = args[2];
    const email = args[3];
    const age_str = args[4];
    const age = try std.fmt.parseInt(i32, age_str, 10);

    var db: ?*sqlite3.sqlite3 = null;
    try checkError(sqlite3.sqlite3_open(db_path, &db));
    defer {
        if (db) |db_ptr| _ = sqlite3.sqlite3_close(db_ptr);
    }
    std.debug.print("Opened DB: {s}\n", .{db_path});

    const create_table_sql =
        \\CREATE TABLE IF NOT EXISTS users (
        \\  id INTEGER PRIMARY KEY,
        \\  name TEXT NOT NULL,
        \\  email TEXT NOT NULL,
        \\  age INTEGER
        \\);
    ;
    try execSql(db, create_table_sql);

    const insert_sql =
        "INSERT INTO users (name, email, age) VALUES (?, ?, ?)";
    var stmt: ?*sqlite3.sqlite3_stmt = null;
    try checkError(
        sqlite3.sqlite3_prepare_v2(db, insert_sql, -1, &stmt, null),
    );

    defer {
        if (stmt) |stmt_ptr| _ = sqlite3.sqlite3_finalize(stmt_ptr);
    }

    try checkError(sqlite3.sqlite3_bind_text(
        stmt,
        1,
        name.ptr,
        std.math.cast(c_int, name.len) orelse
            return error.LengthOverflow,
        null,
    ));

    try checkError(sqlite3.sqlite3_bind_text(
        stmt,
        2,
        email.ptr,
        std.math.cast(c_int, email.len) orelse
            return error.LengthOverflow,
        null,
    ));
    try checkError(sqlite3.sqlite3_bind_int(stmt, 3, age));
    try checkError(sqlite3.sqlite3_step(stmt));

    std.debug.print("User inserted: {s}, {s}, {d}\n", .{
        name, email, age,
    });
}

fn execSql(db: ?*sqlite3.sqlite3, sql: []const u8) !void {
    var err_msg: [*c]u8 = null;
    defer {
        if (err_msg) |msg| sqlite3.sqlite3_free(msg);
    }
    try checkError(
        sqlite3.sqlite3_exec(db, sql.ptr, null, null, &err_msg),
    );
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
