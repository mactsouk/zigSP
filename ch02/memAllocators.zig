const std = @import("std");

fn createNumbers(allocator: std.mem.Allocator) ![]u32 {
    const slice = try allocator.alloc(u32, 4);
    for (slice, 0..) |*item, i| {
        item.* = @intCast(i * 10);
    }
    return slice;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const stdout_file = std.Io.File.stdout();

    // Allocate the buffer explicitly (on stack or heap)
    var buf: [4096]u8 = undefined;

    // Initialize the writer with the buffer.
    // This returns a concrete struct specific to File.
    var stdout_impl = stdout_file.writer(io, &buf);

    // Get the standard 'Writer' interface pointer.
    // We use this interface to call generic methods like .print() and .flush().
    const stdout = &stdout_impl.interface;

    // FLUSH IS MANDATORY: Since we control the buffer, we must ensure
    // it drains before the function exits.
    defer stdout.flush() catch {};

    // --- 2. General Purpose Allocator (GPA) ---
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const gpa_allocator = gpa.allocator();

    const numbers = try createNumbers(gpa_allocator);
    try stdout.print("GPA Numbers: {any}\n", .{numbers});
    gpa_allocator.free(numbers);

    // --- 3. Arena Allocator ---
    var arena = std.heap.ArenaAllocator.init(gpa_allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const n1 = try createNumbers(arena_allocator);
    const n2 = try createNumbers(arena_allocator);
    try stdout.print("Arena Numbers: {any}, {any}\n", .{ n1, n2 });

    // --- 4. Fixed Buffer Allocator ---
    var stack_buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&stack_buffer);
    const fba_allocator = fba.allocator();

    const n3 = try createNumbers(fba_allocator);
    try stdout.print("Stack Numbers: {any}\n", .{n3});
}
