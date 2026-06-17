# The Linux I/O Scheduler and Buffering Strategies

## What the Scheduler Does

The Linux I/O scheduler occupies the block layer, the thin translation stratum between a filesystem and a storage driver.  When a process issues a `read` or `write` call on a buffered file, the virtual filesystem resolbs the request into one or more 512-byte (or 4 KB) sector-aligned block I/O requests and hands them to the scheduler. The scheduler's job is to decide the *order* in which those requests reach the device.  On a spinning disk, reordering adjacent-sector requests into a single sweep of the read head — the classic elevator algorithm — can turn dozens of random seeks into one sequential pass, multiplying throughput by an order of magnitude. On an NVMe solid-state drive, the same reordering provides no benefit: the device's internal parallelism and near-zero seek time make the scheduler's optimizations irrelevant or even counterproductive, so the kernel bypasses it entirely on fast devices.

## Available Schedulers

Linux 5.x exposes several schedulers through `sysfs`.  You can inspect and change the active scheduler per device:

```
cat /sys/block/sda/queue/scheduler
echo mq-deadline | sudo tee /sys/block/sda/queue/scheduler
```

**none** (also called `noop` on older kernels) passes requests straight through with a simple FIFO queue.  It is the default on NVMe drives and virtual block devices where reordering yields nothing and latency is paramount.

**mq-deadline** is the standard choice for HDDs and SATA SSDs.  It partitions requests into read and write queues with per-request deadlines; the scheduler services the queue with the nearest deadline, preventing any single request from starving indefinitely.  The read deadline is 500 ms and the write deadline 5 s by default, tunable via `/sys/block/<dev>/queue/iosched/`.

**Kyber** uses a token-bucket mechanism to give independent latency targets for read and synchronous-write traffic.  It shines on fast multi-queue SSDs where the bottleneck is not seek time but fair access to device queues across processes.

**BFQ** (Budget Fair Queuing) tracks per-process I/O budgets and provides bandwidth guarantees that survive large bursty neighbours.  It is the default on desktop distributions (Fedora, Ubuntu) because it keeps interactive applications — video players, browsers — responsive while a background build or backup is hammering the disk.

The active scheduler is reported in brackets: `[mq-deadline] kyber bfq none`.

## Readahead and the Page Cache

The I/O scheduler and the page cache readahead mechanism are distinct, though they interact.  When the kernel detects a sequential read pattern — successive `read()` calls advancing through a file — the readahead algorithm issues speculative reads several pages ahead of the current position before the application asks for them.  The default readahead window is 128 KB (`/sys/block/<dev>/queue/read_ahead_kb`), though the kernel adjusts it dynamically: a sustained sequential workload pushes the window up; random access collapses it to zero.

Your buffer size choice intersects with readahead in a subtle way.  If your application reads in 512-byte chunks, the kernel must issue many small requests, each potentially stalling until the scheduler acknowledges a CQE, and the readahead algorithm has few opportunities to observe a sequential pattern before you switch position.  If you read in 64 KB chunks, each request covers 16 pages, the scheduler sees fewer but larger block requests that it can merge trivially, and the readahead window tracks comfortably ahead.  The Zig benchmarks in this chapter (`benchmarkReading.zig`) consistently show an inflection around 4–16 KB: below that, syscall overhead and scheduler round-trips dominate; above 64 KB, the gains diminish because the readahead is already doing the prefetching for you.

## Buffered I/O versus Direct I/O

The default `open()` call uses *buffered I/O*: every read populates the page cache, and subsequent reads of the same data return from memory without touching the disk.  Every write goes to the page cache and is eventually written back to disk by the kernel's dirty-page writeback threads.  Buffered I/O is almost always the right choice for programs that access files in a typical pattern: the cache absorbs both temporal locality (re-reading the same region) and write coalescing (multiple small writes to the same page are flushed in one disk I/O).

*Direct I/O* (opened with `O_DIRECT`) bypasses the page cache entirely.  The kernel transfers data straight between the user's buffer and the device DMA engine.  This is appropriate in two situations: when a process manages its own, larger cache — PostgreSQL and MySQL both do this — and when the workload is single-pass sequential (log ingestion, disk imaging) so cached pages would never be reused, only consuming memory.  Direct I/O imposes a strict constraint: the user buffer, the file offset, and the transfer length must all be aligned to the logical block size, typically 512 bytes or 4 KB.  Zig's `extern struct` and `@alignOf` make it straightforward to guarantee this alignment at compile time; a mismatch returns `EINVAL`.

## Practical Guidance for Zig Programs

For sequential file processing — the common case in this chapter — a buffer of 4–64 KB gives near-optimal performance on both HDDs and SSDs.  The exact sweet spot depends on the scheduler in use (BFQ penalises very small requests more than `none` does), the page size (4 KB on x86-64 and aarch64), and the I/O depth: on an NVMe device you may benefit from submitting multiple requests in flight simultaneously, which the Zig `Io` abstraction handles transparently via io_uring on Linux.  The `benchmarkReading.zig` and `benchmarkWriting.zig` programs in this chapter are designed to find your system's sweet spot empirically — run them with a range of buffer sizes and let the numbers guide your production defaults rather than relying on rules of thumb.

For write-heavy workloads, the kernel's writeback is controlled by `vm.dirty_ratio` (the ceiling at which writes start blocking) and `vm.dirty_background_ratio` (the softer threshold at which background flush begins).  If your program writes at a sustained rate that keeps dirty memory above the background threshold, lowering `dirty_background_ratio` or increasing writeback frequency (`vm.dirty_writeback_centisecs`) can reduce latency spikes.  These are system-wide tunables; for a production service, consider whether `O_SYNC` or `fdatasync()` after each logical transaction is a better tradeoff than relying on automatic writeback — it makes durability explicit in the code rather than depending on administrator configuration.
