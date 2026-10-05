const std = @import("std");
// Zig 0.16:
// const sqlite3 = @cImport({
//     @cInclude("sqlite3.h");
// });
// Zig 0.17: zig translate-c -lc deleteSQLite3_c.h > deleteSQLite3_c.zig
const sqlite3 = @import("deleteSQLite3_c.zig");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len != 3) {
        std.debug.print(
            "Usage: {s} <db_path> <name>\n",
            .{args[0]},
        );
        return error.InvalidArgument;
    }

    const db_path = args[1];
    const name = args[2];

    var db: ?*sqlite3.sqlite3 = null;
    try checkError(sqlite3.sqlite3_open(db_path, &db));
    defer {
        if (db) |db_ptr| _ = sqlite3.sqlite3_close(db_ptr);
    }
    std.debug.print("Opened DB: {s}\n", .{db_path});

    // Table and column names cannot be parameterized in
    // SQL — only values can. Interpolating an identifier via fmt
    // opens an SQL injection vector; use a hardcoded or
    // whitelist-validated name instead.
    const delete_sql = "DELETE FROM users WHERE name = ?";

    var stmt: ?*sqlite3.sqlite3_stmt = null;
    try checkError(
        sqlite3.sqlite3_prepare_v2(
            db,
            delete_sql,
            -1,
            &stmt,
            null,
        ),
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

    try checkError(sqlite3.sqlite3_step(stmt));

    const changes = sqlite3.sqlite3_changes(db);
    std.debug.print(
        "Deleted {d} record(s) with name '{s}' from table 'users'.\n",
        .{ changes, name },
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
