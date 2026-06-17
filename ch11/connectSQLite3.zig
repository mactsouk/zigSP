const std = @import("std");
const sqlite3 = @cImport({
    @cInclude("sqlite3.h");
});

pub fn main(init: std.process.Init) !void {
    _ = init;

    // Open or create database
    var db: ?*sqlite3.sqlite3 = null;
    try checkError(sqlite3.sqlite3_open("/tmp/test.db", &db));
    defer {
        if (db) |db_ptr| _ = sqlite3.sqlite3_close(db_ptr);
    }

    std.debug.print("Database opened successfully\n", .{});
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
