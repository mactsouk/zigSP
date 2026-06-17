/// src/bench.zig — zcache benchmark client
///
/// Sends a configurable number of SET/GET/DEL commands as fast as possible
/// over a single TCP connection and reports:
///
///   • Total time
///   • Operations per second (throughput)
///   • Mean, min, max, and p99 latency per operation
///
/// Usage:
///   zig build bench
///   ./zig-out/bin/bench [options]
///
/// Options:
///   --host   H    server host      (default: 127.0.0.1)
///   --port   P    server port      (default: 7777)
///   --ops    N    operations total (default: 100 000)
///   --value  N    value size bytes (default: 64)
///   --keys   N    distinct keys    (default: 1 000)
///   --concurrency N  parallel connections (default: 1). Each worker runs on
///                    its own OS thread with its own connection; the total op
///                    count is split across them. Use this to drive the
///                    server's thread-per-connection path and observe how the
///                    single cache mutex scales (e.g. --concurrency 1/50/200).
///   --mix         run SET+GET+DEL mix instead of pure SET then GET
const std = @import("std");

// ─────────────────────────────────────────────────────────────────────────────
// § 1 · Protocol constants
// ─────────────────────────────────────────────────────────────────────────────

const MAGIC: u8 = 0x5A;
const VERSION: u8 = 0x01;
const PREFIX_LEN: usize = 8;

const CMD_GET: u8 = 0x02;
const CMD_SET: u8 = 0x03;
const CMD_DEL: u8 = 0x04;

const STATUS_OK: u8 = 0x00;
const STATUS_NOT_FOUND: u8 = 0x01;

// ─────────────────────────────────────────────────────────────────────────────
// § 2 · Wire helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Read exactly buf.len bytes from the reader.
/// readSliceAll returns error.EndOfStream if the stream ends early.
fn readExact(r: anytype, buf: []u8) !void {
    try r.readSliceAll(buf);
}

/// Send one ZEMP frame and flush.
fn sendFrame(w: anytype, type_byte: u8, payload: []const u8) !void {
    var prefix: [PREFIX_LEN]u8 = undefined;
    prefix[0] = MAGIC;
    prefix[1] = VERSION;
    prefix[2] = type_byte;
    prefix[3] = 0x00;
    std.mem.writeInt(u32, prefix[4..8], @intCast(payload.len), .big);
    try w.writeAll(&prefix);
    if (payload.len > 0) try w.writeAll(payload);
    try w.flush();
}

/// Drain one response frame. Returns the status byte.
/// Discards the payload — the benchmark does not inspect values.
fn drainFrame(r: anytype, allocator: std.mem.Allocator) !u8 {
    var prefix: [PREFIX_LEN]u8 = undefined;
    try readExact(r, &prefix);
    if (prefix[0] != MAGIC) return error.BadMagic;
    if (prefix[1] != VERSION) return error.UnsupportedVersion;
    const status = prefix[2];
    const payload_len = std.mem.readInt(u32, prefix[4..8], .big);
    if (payload_len > 0) {
        const tmp = try allocator.alloc(u8, payload_len);
        defer allocator.free(tmp);
        try readExact(r, tmp);
    }
    return status;
}

// ─────────────────────────────────────────────────────────────────────────────
// § 3 · Payload builders (written directly into a pre-allocated buffer)
// ─────────────────────────────────────────────────────────────────────────────

/// Write a GET payload for the given key into `buf`.
/// Returns the slice of `buf` actually used.
fn buildGet(buf: []u8, key: []const u8) []u8 {
    std.mem.writeInt(u16, buf[0..2], @intCast(key.len), .big);
    @memcpy(buf[2..][0..key.len], key);
    return buf[0 .. 2 + key.len];
}

/// Write a SET payload into `buf`. Returns the slice actually used.
fn buildSet(buf: []u8, key: []const u8, value: []const u8) []u8 {
    var pos: usize = 0;
    std.mem.writeInt(u16, buf[pos..][0..2], @intCast(key.len), .big);
    pos += 2;
    @memcpy(buf[pos..][0..key.len], key);
    pos += key.len;
    std.mem.writeInt(u32, buf[pos..][0..4], @intCast(value.len), .big);
    pos += 4;
    @memcpy(buf[pos..][0..value.len], value);
    pos += value.len;
    std.mem.writeInt(u64, buf[pos..][0..8], 0, .big);
    pos += 8; // no TTL
    return buf[0..pos];
}

/// Write a DEL payload into `buf`. Returns the slice actually used.
fn buildDel(buf: []u8, key: []const u8) []u8 {
    return buildGet(buf, key); // identical layout: [key_len: u16][key]
}

// ─────────────────────────────────────────────────────────────────────────────
// § 4 · Latency histogram
// ─────────────────────────────────────────────────────────────────────────────

/// Collects per-operation nanosecond timings.
const Histogram = struct {
    samples: []u64, // heap-allocated, one entry per op
    len: usize,

    fn init(allocator: std.mem.Allocator, capacity: usize) !Histogram {
        return .{
            .samples = try allocator.alloc(u64, capacity),
            .len = 0,
        };
    }

    fn deinit(self: *Histogram, allocator: std.mem.Allocator) void {
        allocator.free(self.samples);
    }

    fn record(self: *Histogram, ns: u64) void {
        if (self.len < self.samples.len) {
            self.samples[self.len] = ns;
            self.len += 1;
        }
    }

    fn compute(self: *Histogram) Stats {
        const s = self.samples[0..self.len];
        if (s.len == 0) return .{};

        std.sort.heap(u64, s, {}, std.sort.asc(u64));

        var sum: u64 = 0;
        var min: u64 = s[0];
        var max: u64 = s[0];
        for (s) |v| {
            sum += v;
            if (v < min) min = v;
            if (v > max) max = v;
        }

        const p99_idx = (s.len * 99) / 100;

        return .{
            .mean_us = (sum / s.len) / 1000,
            .min_us = min / 1000,
            .max_us = max / 1000,
            .p99_us = s[p99_idx] / 1000,
        };
    }
};

const Stats = struct {
    mean_us: u64 = 0,
    min_us: u64 = 0,
    max_us: u64 = 0,
    p99_us: u64 = 0,
};

// ─────────────────────────────────────────────────────────────────────────────
// § 5 · Benchmark phases
// ─────────────────────────────────────────────────────────────────────────────

const BenchConfig = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 7777,
    ops: usize = 100_000,
    value_size: usize = 64,
    key_count: usize = 1_000,
    mix: bool = false,
    /// Number of concurrent client connections. Each runs on its own OS thread
    /// (via Io.Group.concurrent) with its own TCP connection, so the server's
    /// thread-per-connection path and single cache mutex are genuinely exercised
    /// in parallel. The total op count is split evenly across the workers.
    concurrency: usize = 1,
};

/// Which workload a worker runs. Runtime (not comptime) so a single worker
/// body can serve every phase when many run concurrently.
const Phase = enum { set, get, del, mix };

/// Format an integer key into `buf` and return the written slice.
/// Keeps key allocation off the heap inside the hot loop.
fn fmtKey(buf: *[32]u8, idx: usize) []u8 {
    return std.fmt.bufPrint(buf, "key:{d}", .{idx}) catch unreachable;
}

/// One concurrent benchmark worker: owns a TCP connection, runs its share of
/// the operations for a single phase, and records per-op latencies into `hist`.
/// Any failure is captured in `err` rather than propagated, because the task
/// body handed to Io.Group must not return an error to the group.
const Worker = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    config: BenchConfig,
    phase: Phase,
    ops: usize, // this worker's share of the total
    key_offset: usize, // staggers keys so workers don't all start on the same one
    hist: Histogram,
    err: ?anyerror = null,

    /// Task entry point. Returns void so it coerces to the `Cancelable!void`
    /// that Io.Group.concurrent expects; errors are stored in `err`.
    fn run(self: *Worker) void {
        self.execute() catch |e| {
            self.err = e;
        };
    }

    fn execute(self: *Worker) !void {
        const addr = try std.Io.net.IpAddress.parseIp4(
            self.config.host,
            self.config.port,
        );
        const stream = try addr.connect(self.io, .{ .mode = .stream });
        defer stream.close(self.io);

        var rbuf: [65536]u8 = undefined;
        var wbuf: [65536]u8 = undefined;
        var reader_impl = stream.reader(self.io, &rbuf);
        var writer_impl = stream.writer(self.io, &wbuf);
        const r = &reader_impl.interface;
        const w = &writer_impl.interface;

        // Pre-allocate a reusable payload buffer (large enough for any op).
        const MAX_KEY = 32;
        const MAX_PAY = 2 + MAX_KEY + 4 + self.config.value_size + 8;
        const pay_buf = try self.allocator.alloc(u8, MAX_PAY);
        defer self.allocator.free(pay_buf);

        // Fixed-content value (we benchmark the cache, not memset).
        const value = try self.allocator.alloc(u8, self.config.value_size);
        defer self.allocator.free(value);
        @memset(value, 'x');

        var key_buf: [MAX_KEY]u8 = undefined;

        for (0..self.ops) |i| {
            const key = fmtKey(&key_buf, (i + self.key_offset) % self.config.key_count);
            const op_start = std.Io.Timestamp.now(self.io, .awake);

            switch (self.phase) {
                .set => {
                    try sendFrame(w, CMD_SET, buildSet(pay_buf, key, value));
                    _ = try drainFrame(r, self.allocator);
                },
                .get => {
                    try sendFrame(w, CMD_GET, buildGet(pay_buf, key));
                    _ = try drainFrame(r, self.allocator);
                },
                .del => {
                    try sendFrame(w, CMD_DEL, buildDel(pay_buf, key));
                    _ = try drainFrame(r, self.allocator);
                },
                .mix => {
                    // 60 % SET, 30 % GET, 10 % DEL
                    const rng = i % 10;
                    if (rng < 6) {
                        try sendFrame(w, CMD_SET, buildSet(pay_buf, key, value));
                    } else if (rng < 9) {
                        try sendFrame(w, CMD_GET, buildGet(pay_buf, key));
                    } else {
                        try sendFrame(w, CMD_DEL, buildDel(pay_buf, key));
                    }
                    _ = try drainFrame(r, self.allocator);
                },
            }

            const op_dur = op_start.durationTo(std.Io.Timestamp.now(self.io, .awake));
            self.hist.record(@intCast(op_dur.nanoseconds));
        }
    }
};

/// Run one phase across `config.concurrency` workers, then report the
/// aggregate result. Throughput is measured against wall-clock time spanning
/// the whole group, so it reflects real concurrent server throughput rather
/// than the sum of independent single-connection runs.
fn runPhase(
    io: std.Io,
    label: []const u8,
    allocator: std.mem.Allocator,
    config: BenchConfig,
    phase: Phase,
) !void {
    const n = @max(config.concurrency, 1);

    const workers = try allocator.alloc(Worker, n);
    defer allocator.free(workers);

    // Split the total op count as evenly as possible across the workers.
    const base = config.ops / n;
    const remainder = config.ops % n;

    for (workers, 0..) |*worker, idx| {
        const share = base + (if (idx < remainder) @as(usize, 1) else 0);
        worker.* = .{
            .io = io,
            .allocator = allocator,
            .config = config,
            .phase = phase,
            .ops = share,
            .key_offset = idx * (config.key_count / n),
            .hist = try Histogram.init(allocator, share),
        };
    }
    defer for (workers) |*worker| worker.hist.deinit(allocator);

    // ── Spawn, time, and join the whole group ─────────────────────────────────
    const t_start = std.Io.Timestamp.now(io, .awake);

    var group: std.Io.Group = .init;
    for (workers) |*worker| {
        try group.concurrent(io, Worker.run, .{worker});
    }
    group.await(io) catch {};

    const total_dur = t_start.durationTo(std.Io.Timestamp.now(io, .awake));
    const elapsed_ns: u64 = @intCast(total_dur.nanoseconds);
    const elapsed_ms = elapsed_ns / std.time.ns_per_ms;

    // ── Surface the first worker error, if any ────────────────────────────────
    for (workers) |*worker| {
        if (worker.err) |e| return e;
    }

    // ── Merge every worker's samples into one histogram for global stats ──────
    var merged = try Histogram.init(allocator, config.ops);
    defer merged.deinit(allocator);
    for (workers) |*worker| {
        for (worker.hist.samples[0..worker.hist.len]) |ns| merged.record(ns);
    }

    const ops_done = merged.len;
    const ops_per_sec = if (elapsed_ns == 0) 0 else ops_done * std.time.ns_per_s / elapsed_ns;
    const stats = merged.compute();

    std.debug.print(
        \\
        \\  {s}   (concurrency={d})
        \\  ─────────────────────────────────────
        \\  ops          : {d}
        \\  total time   : {d} ms
        \\  throughput   : {d} ops/sec
        \\  latency mean : {d} µs
        \\  latency min  : {d} µs
        \\  latency p99  : {d} µs
        \\  latency max  : {d} µs
        \\
    , .{
        label,
        n,
        ops_done,
        elapsed_ms,
        ops_per_sec,
        stats.mean_us,
        stats.min_us,
        stats.p99_us,
        stats.max_us,
    });
}

// ─────────────────────────────────────────────────────────────────────────────
// § 6 · Entry point
// ─────────────────────────────────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    var iter = init.minimal.args.iterate();
    defer iter.deinit();
    _ = iter.next(); // skip argv[0]

    var cfg = BenchConfig{};

    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--host")) {
            cfg.host = iter.next() orelse {
                std.debug.print("--host needs a value\n", .{});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--port")) {
            const s = iter.next() orelse {
                std.debug.print("--port needs a value\n", .{});
                std.process.exit(1);
            };
            cfg.port = std.fmt.parseInt(u16, s, 10) catch {
                std.debug.print("invalid port\n", .{});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--ops")) {
            const s = iter.next() orelse {
                std.debug.print("--ops needs a value\n", .{});
                std.process.exit(1);
            };
            cfg.ops = std.fmt.parseInt(usize, s, 10) catch {
                std.debug.print("invalid --ops\n", .{});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--value")) {
            const s = iter.next() orelse {
                std.debug.print("--value needs a value\n", .{});
                std.process.exit(1);
            };
            cfg.value_size = std.fmt.parseInt(usize, s, 10) catch {
                std.debug.print("invalid --value\n", .{});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--keys")) {
            const s = iter.next() orelse {
                std.debug.print("--keys needs a value\n", .{});
                std.process.exit(1);
            };
            cfg.key_count = std.fmt.parseInt(usize, s, 10) catch {
                std.debug.print("invalid --keys\n", .{});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--concurrency")) {
            const s = iter.next() orelse {
                std.debug.print("--concurrency needs a value\n", .{});
                std.process.exit(1);
            };
            cfg.concurrency = std.fmt.parseInt(usize, s, 10) catch {
                std.debug.print("invalid --concurrency\n", .{});
                std.process.exit(1);
            };
            if (cfg.concurrency == 0) {
                std.debug.print("--concurrency must be >= 1\n", .{});
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "--mix")) {
            cfg.mix = true;
        } else {
            std.debug.print("unknown flag: {s}\n", .{arg});
            std.process.exit(1);
        }
    }

    // ── Header ────────────────────────────────────────────────────────────────
    std.debug.print(
        \\
        \\  zcache benchmark
        \\  host={s}  port={d}  ops={d}  value={d}B  keys={d}  conc={d}  mix={}
        \\
    , .{ cfg.host, cfg.port, cfg.ops, cfg.value_size, cfg.key_count, cfg.concurrency, cfg.mix });

    // ── Run phases ────────────────────────────────────────────────────────────
    // Each phase opens its own connections (one per worker) and tears them down
    // before the next phase begins, so phases never share connection state.
    if (cfg.mix) {
        try runPhase(init.io, "MIXED  (60% SET / 30% GET / 10% DEL)", init.gpa, cfg, .mix);
    } else {
        try runPhase(init.io, "SET", init.gpa, cfg, .set);
        try runPhase(init.io, "GET", init.gpa, cfg, .get);
        try runPhase(init.io, "DEL", init.gpa, cfg, .del);
    }
}
