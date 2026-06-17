/// schedule.zig — core data model for zcron
///
/// Job and Schedule are plain value types with no I/O dependencies,
/// making them easy to unit-test in isolation.
const std = @import("std");

// ─── Constants ────────────────────────────────────────────────────────────────

/// Maximum number of jobs in a single schedule.
pub const MAX_JOBS: usize = 128;

/// Maximum length of a command string (bytes, excluding the null terminator).
pub const MAX_CMD: usize = 512;

// ─── Job ──────────────────────────────────────────────────────────────────────

/// A single scheduled task.
///
/// The command is stored in a fixed-size buffer with an explicit null
/// terminator so it can be handed directly to execveZ() without copying.
pub const Job = struct {
    /// Raw storage: cmd bytes followed by at least one guaranteed zero byte.
    buf: [MAX_CMD + 1]u8,
    /// Number of significant bytes in buf (not counting the terminator).
    len: u16,
    /// Seconds between executions.
    interval_sec: u64,
    /// Unix timestamp of the last successful spawn; 0 means "never run".
    last_run: i64,

    // ── Constructors ──────────────────────────────────────────────────────────

    /// Build a Job from a plain (non-terminated) command slice.
    /// Returns error.CommandTooLong when cmd exceeds MAX_CMD bytes.
    pub fn init(cmd: []const u8, interval_sec: u64) error{CommandTooLong}!Job {
        if (cmd.len > MAX_CMD) return error.CommandTooLong;

        var j = Job{
            .buf = std.mem.zeroes([MAX_CMD + 1]u8),
            .len = @intCast(cmd.len),
            .interval_sec = interval_sec,
            .last_run = 0,
        };
        @memcpy(j.buf[0..cmd.len], cmd);
        // buf[len] is already 0 from zeroes(); make it explicit.
        j.buf[cmd.len] = 0;
        return j;
    }

    // ── Accessors ─────────────────────────────────────────────────────────────

    /// Null-terminated view of the command, safe to pass to execveZ().
    ///
    /// The slice length is self.len; the byte at that index is guaranteed 0.
    pub fn command(self: *const Job) [:0]const u8 {
        return self.buf[0..self.len :0];
    }

    // ── Scheduling predicate ──────────────────────────────────────────────────

    /// Returns true when at least interval_sec seconds have elapsed since
    /// last_run (or when the job has never run).
    pub fn isDue(self: *const Job, now: i64) bool {
        return (now - self.last_run) >= @as(i64, @intCast(self.interval_sec));
    }
};

// ─── Schedule ─────────────────────────────────────────────────────────────────

/// A fixed-capacity collection of Jobs.
///
/// Backed by a stack array so the scheduler never needs a heap allocator
/// after startup.
pub const Schedule = struct {
    jobs: [MAX_JOBS]Job = undefined,
    len: usize = 0,

    /// Append a new job.  Returns error.TooManyJobs once MAX_JOBS is reached.
    pub fn addJob(
        self: *Schedule,
        cmd: []const u8,
        interval: u64,
    ) !void {
        if (self.len >= MAX_JOBS) return error.TooManyJobs;
        self.jobs[self.len] = try Job.init(cmd, interval);
        self.len += 1;
    }

    /// Slice over the live jobs.
    pub fn slice(self: *Schedule) []Job {
        return self.jobs[0..self.len];
    }

    /// Remove all jobs. Used by config.reload() to rebuild from scratch.
    pub fn reset(self: *Schedule) void {
        self.len = 0;
    }
};

// ─── Unit Tests ───────────────────────────────────────────────────────────────

test "Job.isDue — never run" {
    const job = try Job.init("echo hi", 60);
    // last_run == 0 and now > 0: always due
    try std.testing.expect(job.isDue(1_000_000));
}

test "Job.isDue — not yet due" {
    var job = try Job.init("echo hi", 300);
    job.last_run = 1000;
    try std.testing.expect(!job.isDue(1100)); // only 100 s elapsed
}

test "Job.isDue — exactly on interval" {
    var job = try Job.init("echo hi", 300);
    job.last_run = 1000;
    try std.testing.expect(job.isDue(1300));
}

test "Job.command — null terminated" {
    const job = try Job.init("ls -la", 10);
    const cmd = job.command();
    try std.testing.expectEqualStrings("ls -la", cmd);
    try std.testing.expectEqual(@as(u8, 0), cmd.ptr[cmd.len]); // sentinel
}

test "Job.init — command too long" {
    var long: [MAX_CMD + 1]u8 = undefined;
    @memset(&long, 'x');
    try std.testing.expectError(error.CommandTooLong, Job.init(&long, 60));
}

test "Schedule.addJob and slice" {
    var s = Schedule{};
    try s.addJob("echo one", 60);
    try s.addJob("echo two", 120);
    try std.testing.expectEqual(@as(usize, 2), s.len);
    try std.testing.expectEqualStrings("echo one", s.slice()[0].command());
    try std.testing.expectEqualStrings("echo two", s.slice()[1].command());
}
