const std = @import("std");

const Order = std.builtin.AtomicOrder;
const AtomicU32 = std.atomic.Value(u32);
const AtomicBool = std.atomic.Value(bool);
const size = 4;

// Ring buffer with atomic slots
// Zig 0.16: [_]AtomicU32{AtomicU32.init(0)} ** size
var buffer: [size]AtomicU32 = @splat(AtomicU32.init(0));
// Zig 0.16: [_]AtomicBool{AtomicBool.init(false)} ** size
var fullFlags: [size]AtomicBool = @splat(AtomicBool.init(false));

var producerIndex = std.atomic.Value(usize).init(0);
var consumerIndex = std.atomic.Value(usize).init(0);
var done = AtomicBool.init(false);

const WorkerArgs = struct { io: std.Io };

fn producer(args: WorkerArgs) void {
    var value: u32 = 1;
    while (value <= 10) {
        const pi = producerIndex.load(Order.acquire);
        const index = pi % size;
        if (!fullFlags[index].load(Order.acquire)) {
            buffer[index].store(value, Order.release);
            fullFlags[index].store(true, Order.release);
            std.debug.print(
                "Produced: {d} at {d}\n",
                .{ value, index },
            );
            producerIndex.store(pi + 1, Order.release);
            value += 1;
        } else {
            std.Io.sleep(
                args.io,
                std.Io.Duration.fromMicroseconds(10),
                .awake,
            ) catch {}; // buffer slot is full
        }
    }
    done.store(true, Order.release);
}

fn consumer(args: WorkerArgs) void {
    while (true) {
        const ci = consumerIndex.load(Order.acquire);
        const index = ci % size;

        if (done.load(Order.acquire) and !fullFlags[index].load(
            Order.acquire,
        )) {
            break;
        }

        if (fullFlags[index].load(Order.acquire)) {
            const val = buffer[index].load(Order.acquire);
            std.debug.print("Consumed: {d} from {d}\n", .{ val, index });
            fullFlags[index].store(false, Order.release);
            consumerIndex.store(ci + 1, Order.release);
        } else {
            std.Io.sleep(
                args.io,
                std.Io.Duration.fromMicroseconds(10),
                .awake,
            ) catch {}; // wait for data
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const prod = try std.Thread.spawn(
        .{},
        producer,
        .{WorkerArgs{ .io = io }},
    );
    const cons = try std.Thread.spawn(
        .{},
        consumer,
        .{WorkerArgs{ .io = io }},
    );
    prod.join();
    cons.join();
}
