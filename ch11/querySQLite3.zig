const std = @import("std");
// Zig 0.16:
// const sqlite3 = @cImport({
//     @cInclude("sqlite3.h");
// });
// Zig 0.17: zig translate-c -lc querySQLite3_c.h > querySQLite3_c.zig
const sqlite3 = @import("querySQLite3_c.zig");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 2) {
        std.debug.print("Usage: {s} <db_path>\n", .{args[0]});
        return error.InvalidArgument;
    }
    const db_path = args[1];

    var db: ?*sqlite3.sqlite3 = null;
    try checkError(sqlite3.sqlite3_open(db_path, &db));
    defer {
        if (db) |db_ptr| _ = sqlite3.sqlite3_close(db_ptr);
    }
    std.debug.print("Database opened successfully: {s}\n", .{db_path});

    const query_sql = "SELECT id, name, email, age FROM users";
    var query_stmt: ?*sqlite3.sqlite3_stmt = null;
    try checkError(sqlite3.sqlite3_prepare_v2(
        db,
        query_sql,
        -1,
        &query_stmt,
        null,
    ));
    defer {
        if (query_stmt) |stmt_ptr|
            _ = sqlite3.sqlite3_finalize(stmt_ptr);
    }

    std.debug.print("\nUser Records:\n", .{});
    std.debug.print(
        "{s: >5} | {s: <10} | {s: <20} | {s: >3}\n",
        .{ "ID", "Name", "Email", "Age" },
    );
    std.debug.print(
        "{s:-<5} | {s:-<10} | {s:-<20} | {s:-<3}\n",
        .{ "", "", "", "" },
    );

    while (sqlite3.sqlite3_step(query_stmt) == sqlite3.SQLITE_ROW) {
        const id = @as(
            u32,
            @intCast(sqlite3.sqlite3_column_int(query_stmt, 0)),
        );
        const name = std.mem.span(
            sqlite3.sqlite3_column_text(query_stmt, 1),
        );
        const email = std.mem.span(
            sqlite3.sqlite3_column_text(query_stmt, 2),
        );
        const age = @as(
            u32,
            @intCast(sqlite3.sqlite3_column_int(query_stmt, 3)),
        );

        std.debug.print(
            "{d: >5} | {s: <10} | {s: <20} | {d: >3}\n",
            .{ id, name, email, age },
        );
    }
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
