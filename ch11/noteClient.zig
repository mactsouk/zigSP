const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var iter = init.minimal.args.iterate();
    defer iter.deinit();

    const program_name = iter.next() orelse {
        std.debug.print("Error: No program name provided\n", .{});
        return error.InvalidArguments;
    };

    var host: []const u8 = "127.0.0.1";
    var port: u16 = 8080;
    var command: ?[]const u8 = null;
    var command_args: std.ArrayListUnmanaged([]const u8) = .empty;
    defer command_args.deinit(allocator);

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
                std.debug.print("Error: Invalid port '{s}'\n", .{port_str});
                return error.InvalidPort;
            };
            if (port == 0) {
                std.debug.print("Error: Port must be between 1 and 65535\n", .{});
                return error.InvalidPort;
            }
        } else {
            if (command == null) {
                command = arg;
            } else {
                try command_args.append(allocator, arg);
            }
        }
    }

    if (command == null) {
        printUsage(program_name);
        return error.InvalidArguments;
    }

    var uri_buf: [256]u8 = undefined;
    const base_uri = try std.fmt.bufPrint(
        &uri_buf,
        "http://{s}:{d}",
        .{ host, port },
    );

    var path_buf: [4096]u8 = undefined;
    const uri = try buildUri(
        allocator,
        command.?,
        command_args.items,
        base_uri,
        &path_buf,
    );

    const method: std.http.Method =
        if (std.mem.eql(u8, command.?, "delete")) .POST else .GET;

    var client = std.http.Client{ .allocator = allocator, .io = init.io };
    defer client.deinit();

    var response_writer = std.Io.Writer.Allocating.init(allocator);
    defer response_writer.deinit();

    const result = try client.fetch(.{
        .location = .{ .uri = try std.Uri.parse(uri) },
        .method = method,
        .response_writer = &response_writer.writer,
    });

    if (result.status != .ok) {
        const phrase = result.status.phrase() orelse "Unknown";
        const code = @intFromEnum(result.status);
        std.debug.print("Error: HTTP {s} ({d})\n", .{ phrase, code });
        return error.HttpError;
    }

    const body = response_writer.writer.buffer[0..response_writer.writer.end];
    if (body.len > 0) {
        std.debug.print("{s}\n", .{body});
    } else {
        std.debug.print("No response body\n", .{});
    }
}

fn buildUri(
    allocator: std.mem.Allocator,
    command: []const u8,
    args: []const []const u8,
    base_uri: []const u8,
    path_buf: *[4096]u8,
) ![]const u8 {
    if (std.mem.eql(u8, command, "status")) {
        if (args.len != 0) {
            std.debug.print("Error: 'status' takes no arguments\n", .{});
            return error.InvalidArguments;
        }
        return try std.fmt.bufPrint(path_buf, "{s}/status", .{base_uri});
    } else if (std.mem.eql(u8, command, "list")) {
        if (args.len != 0) {
            std.debug.print("Error: 'list' takes no arguments\n", .{});
            return error.InvalidArguments;
        }
        return try std.fmt.bufPrint(path_buf, "{s}/list", .{base_uri});
    } else if (std.mem.eql(u8, command, "search")) {
        if (args.len == 0) {
            std.debug.print("Error: 'search' requires a query\n", .{});
            return error.InvalidArguments;
        }
        const query = try joinArgs(allocator, args);
        defer allocator.free(query);
        const encoded_query = try urlEncode(allocator, query);
        defer allocator.free(encoded_query);
        return try std.fmt.bufPrint(path_buf, "{s}/search?q={s}", .{ base_uri, encoded_query });
    } else if (std.mem.eql(u8, command, "insert")) {
        if (args.len < 2) {
            std.debug.print("Error: 'insert' requires title and content\n", .{});
            return error.InvalidArguments;
        }
        const title = try joinArgs(allocator, args[0..1]);
        defer allocator.free(title);
        const content = try joinArgs(allocator, args[1..]);
        defer allocator.free(content);
        const encoded_title = try urlEncode(allocator, title);
        defer allocator.free(encoded_title);
        const encoded_content = try urlEncode(allocator, content);
        defer allocator.free(encoded_content);
        return try std.fmt.bufPrint(
            path_buf,
            "{s}/insert?title={s}&content={s}",
            .{ base_uri, encoded_title, encoded_content },
        );
    } else if (std.mem.eql(u8, command, "delete")) {
        if (args.len != 1) {
            std.debug.print("Error: 'delete' requires an ID\n", .{});
            return error.InvalidArguments;
        }
        const id = std.fmt.parseInt(i32, args[0], 10) catch {
            std.debug.print("Error: Invalid ID '{s}'\n", .{args[0]});
            return error.InvalidId;
        };
        return try std.fmt.bufPrint(path_buf, "{s}/delete?id={d}", .{ base_uri, id });
    } else {
        std.debug.print("Error: Unknown command '{s}'\n", .{command});
        return error.InvalidCommand;
    }
}

fn printUsage(program_name: []const u8) void {
    std.debug.print(
        "Usage: {s} [--host <host>] [--port <port>] <command> [args]\n" ++
            "Commands:\n" ++
            "  status\n" ++
            "  list\n" ++
            "  search <query>\n" ++
            "  insert <title> <content>\n" ++
            "  delete <id>\n",
        .{program_name},
    );
}

fn joinArgs(allocator: std.mem.Allocator, args: []const []const u8) ![]const u8 {
    return try std.mem.join(allocator, " ", args);
}

fn urlEncode(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var output: std.ArrayListUnmanaged(u8) = .empty;
    defer output.deinit(allocator);
    try output.ensureTotalCapacity(allocator, input.len * 3);

    for (input) |c| {
        if (isUrlSafe(c)) {
            try output.append(allocator, c);
        } else {
            var hex: [3]u8 = undefined;
            const s = try std.fmt.bufPrint(&hex, "%{X:0>2}", .{c});
            try output.appendSlice(allocator, s);
        }
    }

    return output.toOwnedSlice(allocator);
}

fn isUrlSafe(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => true,
        else => false,
    };
}
