const std = @import("std");
const sqlite3 = @cImport({
    @cInclude("sqlite3.h");
});
const c = @cImport({
    @cInclude("signal.h");
});

// Only async-signal-safe operations are permitted inside a signal handler.
// std.process.exit and std.debug.print are both unsafe (they acquire locks
// and flush stdio). The atomic flag pattern is the correct alternative: the
// handler does one store, the accept loop checks the flag on each iteration.
var g_running: std.atomic.Value(bool) = .init(true);

export fn handle_sigint(sig: c_int) callconv(.c) void {
    _ = sig;
    g_running.store(false, .release);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;
    _ = c.signal(c.SIGINT, handle_sigint);

    var iter = init.minimal.args.iterate();
    defer iter.deinit();

    _ = iter.next() orelse {
        std.debug.print("Error: No program name provided\n", .{});
        return error.InvalidArguments;
    };

    var host: []const u8 = "127.0.0.1";
    var port: u16 = 8080;
    var db_path: []const u8 = "/tmp/notes.db";

    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--host")) {
            host = iter.next() orelse {
                std.debug.print("Error: --host requires a value\n", .{});
                return error.InvalidArguments;
            };
        } else if (std.mem.eql(u8, arg, "--port")) {
            const port_str = iter.next() orelse {
                std.debug.print("Error: --port requires a value\n", .{});
                return error.InvalidArguments;
            };
            port = std.fmt.parseInt(u16, port_str, 10) catch {
                std.debug.print(
                    "Error: Invalid port '{s}'\n",
                    .{port_str},
                );
                return error.InvalidPort;
            };
            if (port == 0) {
                std.debug.print(
                    "Error: Port must be between 1 and 65535\n",
                    .{},
                );
                return error.InvalidPort;
            }
        } else if (std.mem.eql(u8, arg, "--db")) {
            db_path = iter.next() orelse {
                std.debug.print("Error: --db requires a value\n", .{});
                return error.InvalidArguments;
            };
            if (db_path.len == 0) {
                std.debug.print(
                    "Error: Database path cannot be empty\n",
                    .{},
                );
                return error.InvalidDatabasePath;
            }
        } else {
            std.debug.print("Error: Unknown argument '{s}'\n", .{arg});
            return error.InvalidArguments;
        }
    }

    const addr = try std.Io.net.IpAddress.parseIp4(host, port);
    var listener = try addr.listen(io, .{});
    defer listener.deinit(io);
    std.debug.print("Listening on http://{s}:{d}\n", .{ host, port });

    var db: ?*sqlite3.sqlite3 = null;
    try check(sqlite3.sqlite3_open(db_path.ptr, &db));
    defer {
        if (db) |ptr| {
            _ = sqlite3.sqlite3_close(ptr);
        }
    }
    const db_ptr = db orelse return error.DatabaseError;

    const create_sql =
        "CREATE TABLE IF NOT EXISTS notes (" ++
        "id INTEGER PRIMARY KEY AUTOINCREMENT," ++
        "title TEXT NOT NULL," ++
        "content TEXT NOT NULL" ++
        ");";
    try exec(db_ptr, create_sql);

    while (g_running.load(.acquire)) {
        const stream = listener.accept(io) catch |err| {
            if (!g_running.load(.acquire)) break;
            std.log.warn("accept error: {s}", .{@errorName(err)});
            continue;
        };
        handleConnection(io, stream, allocator, db_ptr) catch |err| {
            std.log.debug("connection error: {s}", .{@errorName(err)});
        };
    }
    std.debug.print("Caught SIGINT, shutting down\n", .{});
}

fn getPath(target: []const u8) []const u8 {
    if (std.mem.findScalar(u8, target, '?')) |p| {
        return target[0..p];
    }
    return target;
}

fn handleConnection(
    io: std.Io,
    stream: std.Io.net.Stream,
    alloc: std.mem.Allocator,
    db: *sqlite3.sqlite3,
) !void {
    defer stream.close(io);

    var reader_buf: [4096]u8 = undefined;
    var writer_buf: [4096]u8 = undefined;
    var r_impl = stream.reader(io, &reader_buf);
    var w_impl = stream.writer(io, &writer_buf);
    var http = std.http.Server.init(
        &r_impl.interface,
        &w_impl.interface,
    );
    var req = try http.receiveHead();
    const method = req.head.method;
    const target = req.head.target;
    const raw = getRawQuery(target);

    const path = getPath(target);
    std.debug.print("Path {s}\n", .{path});

    if (std.mem.eql(u8, path, "/status")) {
        try respondText(&req, "Server is running OK");
        return;
    }
    if (std.mem.eql(u8, path, "/list")) {
        try listNotes(db, alloc, &req);
        return;
    }
    if (std.mem.startsWith(u8, path, "/search")) {
        const q = lookupParam(raw, "q") orelse "";
        try searchNotes(db, alloc, &req, q);
        return;
    }
    if (std.mem.eql(u8, path, "/insert") and method == .GET) {
        const title = lookupParam(raw, "title") orelse "";
        const content = lookupParam(raw, "content") orelse "";
        try insertNote(db, alloc, &req, title, content);
        return;
    }
    if (std.mem.eql(u8, path, "/delete") and method == .POST) {
        const id_str = lookupParam(raw, "id") orelse "0";
        const id = std.fmt.parseInt(i32, id_str, 10) catch 0;
        try deleteNote(db, &req, id);
        return;
    }

    try req.respond("Error: Not found\n", .{
        .status = .not_found,
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = "text/plain" },
        },
    });
}

fn respondText(req: *std.http.Server.Request, body: []const u8) !void {
    try req.respond(body, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = "text/plain" },
        },
    });
}

fn getRawQuery(target: []const u8) []const u8 {
    if (std.mem.findScalar(u8, target, '?')) |p| {
        return target[p + 1 ..];
    }
    return "";
}

fn lookupParam(raw: []const u8, key: []const u8) ?[]const u8 {
    var start: usize = 0;
    while (start < raw.len) {
        const idxFunc = std.mem.findScalarPos;
        const eq_pos = idxFunc(u8, raw, start, '=') orelse break;
        const amp_pos = idxFunc(u8, raw, eq_pos, '&') orelse raw.len;

        const k = raw[start..eq_pos];
        const v = raw[eq_pos + 1 .. amp_pos];

        if (std.mem.eql(u8, k, key)) {
            return v;
        }

        start = amp_pos + 1;
    }
    return null;
}

fn exec(db: *sqlite3.sqlite3, sql: []const u8) !void {
    var err_msg: [*c]u8 = null;
    defer {
        if (err_msg != null) {
            sqlite3.sqlite3_free(err_msg);
        }
    }

    const rc = sqlite3.sqlite3_exec(db, sql.ptr, null, null, &err_msg);

    if (rc != sqlite3.SQLITE_OK) {
        if (err_msg) |msg| {
            std.debug.print("SQL error: {s}\n", .{msg});
        }
        return error.SqliteError;
    }
}

fn listNotes(
    db: *sqlite3.sqlite3,
    alloc: std.mem.Allocator,
    req: *std.http.Server.Request,
) !void {
    const sql = "SELECT id, title, content FROM notes";
    var stmt: ?*sqlite3.sqlite3_stmt = null;
    try check(sqlite3.sqlite3_prepare_v2(db, sql, -1, &stmt, null));
    defer {
        if (stmt) |s| {
            _ = sqlite3.sqlite3_finalize(s);
        }
    }

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();

    var count: i32 = 0;
    while (sqlite3.sqlite3_step(stmt.?) == sqlite3.SQLITE_ROW) {
        count += 1;
        const id = sqlite3.sqlite3_column_int(stmt.?, 0);
        const title = std.mem.span(
            sqlite3.sqlite3_column_text(stmt.?, 1),
        );
        const content = std.mem.span(
            sqlite3.sqlite3_column_text(stmt.?, 2),
        );

        try aw.writer.print("Note #{d}\n", .{id});
        try aw.writer.print("Title: {s}\n", .{title});
        try aw.writer.print("Content: {s}\n", .{content});
        try aw.writer.writeAll("---\n");
    }

    if (count == 0) {
        try aw.writer.writeAll("No notes found.");
    } else {
        try aw.writer.print("Total notes: {d}\n", .{count});
    }

    try respondText(req, aw.writer.buffer[0..aw.writer.end]);
}

fn searchNotes(
    db: *sqlite3.sqlite3,
    alloc: std.mem.Allocator,
    req: *std.http.Server.Request,
    query: []const u8,
) !void {
    const sql = "SELECT id, title, content FROM notes " ++
        "WHERE title LIKE ? OR content LIKE ?";
    var stmt: ?*sqlite3.sqlite3_stmt = null;
    try check(
        sqlite3.sqlite3_prepare_v2(db, sql, -1, &stmt, null),
    );
    defer {
        if (stmt) |s| {
            _ = sqlite3.sqlite3_finalize(s);
        }
    }

    std.debug.print("Query: {s}\n", .{query});
    const pattern = try std.fmt.allocPrint(alloc, "%{s}%", .{query});
    defer alloc.free(pattern);

    try check(sqlite3.sqlite3_bind_text(
        stmt.?,
        1,
        pattern.ptr,
        @as(c_int, @intCast(pattern.len)),
        null,
    ));
    try check(sqlite3.sqlite3_bind_text(
        stmt.?,
        2,
        pattern.ptr,
        @as(c_int, @intCast(pattern.len)),
        null,
    ));

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();

    try aw.writer.writeAll("Search results for: ");
    try aw.writer.writeAll(query);
    try aw.writer.writeAll("\n\n");

    var count: i32 = 0;
    while (sqlite3.sqlite3_step(stmt.?) == sqlite3.SQLITE_ROW) {
        count += 1;
        const id = sqlite3.sqlite3_column_int(stmt.?, 0);
        const title = std.mem.span(
            sqlite3.sqlite3_column_text(stmt.?, 1),
        );
        const content = std.mem.span(
            sqlite3.sqlite3_column_text(stmt.?, 2),
        );

        try aw.writer.print("Note #{d}\n", .{id});
        try aw.writer.print("Title: {s}\n", .{title});
        try aw.writer.print("Content: {s}\n", .{content});
        try aw.writer.writeAll("---\n");
    }

    if (count == 0) {
        try aw.writer.writeAll("No matching notes found.");
    } else {
        try aw.writer.print(
            "Found {d} matching note(s).",
            .{count},
        );
    }

    try respondText(req, aw.writer.buffer[0..aw.writer.end]);
}

fn insertNote(
    db: *sqlite3.sqlite3,
    alloc: std.mem.Allocator,
    req: *std.http.Server.Request,
    title: []const u8,
    content: []const u8,
) !void {
    if (title.len == 0 or content.len == 0) {
        try req.respond("Error: title and content must not be empty\n", .{
            .status = .bad_request,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/plain" },
            },
        });
        return;
    }

    const sql = "INSERT INTO notes (title, content) VALUES (?, ?)";
    var stmt: ?*sqlite3.sqlite3_stmt = null;
    try check(sqlite3.sqlite3_prepare_v2(db, sql, -1, &stmt, null));
    defer {
        if (stmt) |s| {
            _ = sqlite3.sqlite3_finalize(s);
        }
    }

    const bindText = sqlite3.sqlite3_bind_text;

    try check(
        bindText(stmt.?, 1, title.ptr, @intCast(title.len), null),
    );
    try check(
        bindText(
            stmt.?,
            2,
            content.ptr,
            @intCast(content.len),
            null,
        ),
    );

    const rc = sqlite3.sqlite3_step(stmt.?);
    if (rc != sqlite3.SQLITE_DONE) {
        try respondText(req, "Error: Failed to insert note");
        return;
    }

    const new_id = sqlite3.sqlite3_last_insert_rowid(db);
    const body = try std.fmt.allocPrint(
        alloc,
        "Note successfully created with ID: {d}",
        .{new_id},
    );
    defer alloc.free(body);
    try respondText(req, body);
}

fn deleteNote(
    db: *sqlite3.sqlite3,
    req: *std.http.Server.Request,
    id: i32,
) !void {
    const sql = "DELETE FROM notes WHERE id = ?";
    var stmt: ?*sqlite3.sqlite3_stmt = null;
    try check(sqlite3.sqlite3_prepare_v2(db, sql, -1, &stmt, null));
    defer {
        if (stmt) |s| {
            _ = sqlite3.sqlite3_finalize(s);
        }
    }

    try check(sqlite3.sqlite3_bind_int(stmt.?, 1, id));
    const rc = sqlite3.sqlite3_step(stmt.?);

    if (rc != sqlite3.SQLITE_DONE) {
        try respondText(req, "Error: Failed to delete note");
    } else {
        try respondText(req, "Note successfully deleted");
    }
}

fn check(rc: c_int) !void {
    if (rc != sqlite3.SQLITE_OK and
        rc != sqlite3.SQLITE_ROW and
        rc != sqlite3.SQLITE_DONE)
    {
        return error.SqliteError;
    }
}
