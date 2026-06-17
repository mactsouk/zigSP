const std = @import("std");

const AtomicU64 = std.atomic.Value(u64);

// sentinel stored in every slot before the computing thread writes it
const unset: u64 = std.math.maxInt(u64);

const FibArgs = struct {
    io: std.Io,
    index: usize,
    fibs: []AtomicU64,
};

fn fib_worker(arg: *FibArgs) void {
    const i = arg.index;
    const fibs = arg.fibs;

    if (i == 0) {
        fibs[0].store(0, .release);
        return;
    }
    if (i == 1) {
        fibs[1].store(1, .release);
        return;
    }

    // Busy-wait until both predecessors have published their values.
    // .acquire pairs with the .release stores above and below, establishing
    // a happens-before edge so the addition below sees the correct values.
    while (fibs[i - 1].load(.acquire) == unset or
        fibs[i - 2].load(.acquire) == unset)
    {
        std.Io.sleep(
            arg.io,
            std.Io.Duration.fromMicroseconds(1),
            .awake,
        ) catch {};
    }

    fibs[i].store(
        fibs[i - 1].load(.acquire) + fibs[i - 2].load(.acquire),
        .release,
    );
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    if (argv.len != 2) {
        std.debug.print("Usage: {s} <n>\n", .{argv[0]});
        return error.InvalidArguments;
    }

    const n = try std.fmt.parseInt(usize, argv[1], 10);
    if (n == 0) return error.InvalidArguments;

    const fibs = try allocator.alloc(AtomicU64, n);
    defer allocator.free(fibs);
    for (fibs) |*f| f.* = AtomicU64.init(unset);

    var threads = try allocator.alloc(std.Thread, n);
    defer allocator.free(threads);

    var nArgs = try allocator.alloc(FibArgs, n);
    defer allocator.free(nArgs);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        nArgs[i] = FibArgs{ .io = io, .index = i, .fibs = fibs };
        threads[i] = try std.Thread.spawn(
            .{},
            fib_worker,
            .{&nArgs[i]},
        );
    }

    for (threads) |t| t.join();

    std.debug.print("Fibonacci sequence:\n", .{});
    var j: usize = 0;
    while (j < fibs.len) : (j += 1) {
        std.debug.print(
            "  fib[{d}] = {d}\n",
            .{ j, fibs[j].load(.acquire) },
        );
    }
}
