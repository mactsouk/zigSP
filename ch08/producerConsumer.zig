const std = @import("std");

// Atomic producer-consumer with a single-slot buffer.
// Both threads busy-wait with 10us sleep loops, so this is NOT faster
// than a condvar design — a condvar suspends the thread until signaled,
// with zero polling. Atomics give fine-grained control; misapplied
// (busy-wait on a single slot), they trade simplicity for higher CPU
// usage and lower throughput than std.Thread.Mutex + std.Thread.Condition.
const AtomicU32 = std.atomic.Value(u32);
const AtomicBool = std.atomic.Value(bool);
const Order = std.builtin.AtomicOrder;

var buffer: AtomicU32 = AtomicU32.init(0);
var full: AtomicBool = AtomicBool.init(false);
var done: AtomicBool = AtomicBool.init(false);

const WorkerArgs = struct { io: std.Io };

fn producer(args: WorkerArgs) void {
    var value: u32 = 1;
    while (value <= 5) {
        while (full.load(Order.acquire)) {
            std.Io.sleep(
                args.io,
                std.Io.Duration.fromMicroseconds(10),
                .awake,
            ) catch {}; // wait until buffer is free
        }

        buffer.store(value, Order.release);
        full.store(true, Order.release);
        std.debug.print("Produced: {d}\n", .{value});
        value += 1;
    }

    done.store(true, Order.release);
}

fn consumer(args: WorkerArgs) void {
    while (true) {
        if (done.load(Order.acquire) and !full.load(
            Order.acquire,
        )) break;

        if (full.load(Order.acquire)) {
            const val = buffer.load(Order.acquire);
            std.debug.print("Consumed: {d}\n", .{val});
            full.store(false, Order.release);
        } else {
            std.Io.sleep(
                args.io,
                std.Io.Duration.fromMicroseconds(10),
                .awake,
            ) catch {}; // wait for producer
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const t1 = try std.Thread.spawn(.{}, producer, .{WorkerArgs{ .io = io }});
    const t2 = try std.Thread.spawn(.{}, consumer, .{WorkerArgs{ .io = io }});
    t1.join();
    t2.join();
}
