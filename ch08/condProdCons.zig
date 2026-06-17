const std = @import("std");

const max_buffer_size = 5;
var buffer: [max_buffer_size]u32 = undefined;
var count: usize = 0;
var head: usize = 0; // next slot to consume
var tail: usize = 0; // next slot to produce

var mutex: std.Io.Mutex = .init;
var cond: std.Io.Condition = .init;

const ProducerArgs = struct { io: std.Io, n: u32 };
const ConsumerArgs = struct { io: std.Io, n: u32 };

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    if (argv.len != 3) {
        std.debug.print(
            "Usage: {s} <num_producers> <num_consumers>\n",
            .{argv[0]},
        );
        return error.InvalidArgs;
    }

    const numProducers = try std.fmt.parseInt(u32, argv[1], 10);
    const numConsumers = try std.fmt.parseInt(u32, argv[2], 10);

    const producer = try std.Thread.spawn(
        .{},
        producerThread,
        .{ProducerArgs{ .io = io, .n = numProducers }},
    );
    const consumer = try std.Thread.spawn(
        .{},
        consumerThread,
        .{ConsumerArgs{ .io = io, .n = numConsumers }},
    );

    producer.join();
    consumer.join();
}

fn producerThread(args: ProducerArgs) void {
    var i: u32 = 1;
    while (i <= args.n) : (i += 1) {
        mutex.lock(args.io) catch return;
        while (count == max_buffer_size) {
            std.debug.print("Producer waiting: Buffer full\n", .{});
            cond.wait(args.io, &mutex) catch {
                mutex.unlock(args.io);
                return;
            };
        }

        buffer[tail] = i;
        tail = (tail + 1) % max_buffer_size;
        count += 1;
        std.debug.print("Produced: {}\n", .{i});

        cond.signal(args.io);
        mutex.unlock(args.io);
        std.Io.sleep(
            args.io,
            std.Io.Duration.fromMilliseconds(100),
            .awake,
        ) catch {};
    }
    std.debug.print("Producer finished.\n", .{});
}

fn consumerThread(args: ConsumerArgs) void {
    var i: usize = 0;
    while (i < args.n) : (i += 1) {
        mutex.lock(args.io) catch return;
        while (count == 0) {
            std.debug.print("Consumer waiting: Buffer empty\n", .{});
            cond.wait(args.io, &mutex) catch {
                mutex.unlock(args.io);
                return;
            };
        }

        const item = buffer[head];
        head = (head + 1) % max_buffer_size;
        count -= 1;
        std.debug.print("Consumed: {}\n", .{item});

        cond.signal(args.io);
        mutex.unlock(args.io);
        std.Io.sleep(
            args.io,
            std.Io.Duration.fromMilliseconds(200),
            .awake,
        ) catch {};
    }
    std.debug.print("Consumer finished.\n", .{});
}
