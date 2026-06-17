/// src/main.zig — Zcache entry point
///
/// Parses CLI flags, wires together the Cache and Server, then runs.
///
/// Usage:
///   zcache [--host <addr>] [--port <port>] [--capacity <n>]
///
/// Examples:
///   ./zcache                           # defaults: 127.0.0.1:7777, 10 000 entries
///   ./zcache --port 6380 --capacity 1000000
const std = @import("std");
const Cache = @import("cache.zig").Cache;
const CacheConfig = @import("cache.zig").CacheConfig;
const Server = @import("server.zig").Server;
const ServerConfig = @import("server.zig").ServerConfig;

pub fn main(init: std.process.Init) !void {
    // ── CLI argument parsing ─────────────────────────────────────────────────
    var iter = init.minimal.args.iterate();
    defer iter.deinit();
    _ = iter.next(); // skip argv[0]

    var server_cfg = ServerConfig{};
    var cache_cfg = CacheConfig{};

    while (iter.next()) |flag| {
        if (std.mem.eql(u8, flag, "--host")) {
            server_cfg.host = iter.next() orelse fatal("--host requires a value");
        } else if (std.mem.eql(u8, flag, "--port")) {
            const s = iter.next() orelse fatal("--port requires a value");
            server_cfg.port = std.fmt.parseInt(u16, s, 10) catch fatal("invalid port");
        } else if (std.mem.eql(u8, flag, "--capacity")) {
            const s = iter.next() orelse fatal("--capacity requires a value");
            cache_cfg.capacity = std.fmt.parseInt(usize, s, 10) catch fatal("invalid capacity");
        } else if (std.mem.eql(u8, flag, "--max-clients")) {
            const s = iter.next() orelse fatal("--max-clients requires a value");
            server_cfg.max_clients = std.fmt.parseInt(usize, s, 10) catch fatal("invalid max-clients");
        } else {
            std.log.warn("unknown flag: {s}", .{flag});
        }
    }

    // ── Banner ───────────────────────────────────────────────────────────────
    std.log.info(
        \\
        \\  ▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀
        \\       Zcache — in-memory cache
        \\  ▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄
        \\  host      : {s}
        \\  port      : {d}
        \\  capacity  : {d} entries
        \\  max conn  : {d}
        \\  protocol  : ZEMP v1 (binary)
        \\
    , .{
        server_cfg.host,
        server_cfg.port,
        cache_cfg.capacity,
        server_cfg.max_clients,
    });

    // ── Initialise the storage engine ────────────────────────────────────────
    var cache = try Cache.init(init.gpa, cache_cfg);
    defer cache.deinit();

    // ── Initialise and run the server ────────────────────────────────────────
    var server = try Server.init(init.gpa, &cache, server_cfg);
    defer server.deinit();

    // Runs the accept loop forever; returns only on an unrecoverable error.
    // Note: there is no graceful-shutdown path — Ctrl+C (SIGINT) terminates the
    // process immediately. See the chapter for how a signal handler + an atomic
    // flag would let this loop exit cleanly.
    try server.run(init.io);
}

fn fatal(msg: []const u8) noreturn {
    std.log.err("{s}", .{msg});
    std.process.exit(1);
}
