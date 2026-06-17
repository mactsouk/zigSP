const std = @import("std");
const builtin = @import("builtin");
const print = std.debug.print;

pub fn main(init: std.process.Init) !void {
    // --- Securely seeded PRNG ---
    // io.random() seeds from the OS entropy source where possible,
    // but falls back to a less secure mechanism on failure.
    // This makes the initial state unpredictable but the algorithm
    // (Xoshiro256++) remains deterministic and is NOT a CSPRNG.
    var seed_bytes: [8]u8 = undefined;
    init.io.random(&seed_bytes);
    var seeded_prng = std.Random.DefaultPrng.init(
        @bitCast(seed_bytes),
    );
    const rand_seeded = seeded_prng.random();

    print("Seeded PRNG u8:        {}\n", .{rand_seeded.int(u8)});
    print(
        "Seeded PRNG u8 < 10:   {}\n",
        .{rand_seeded.uintLessThan(u8, 10)},
    );
    print("Seeded PRNG u16:       {}\n", .{rand_seeded.int(u16)});
    print("Seeded PRNG u32:       {}\n", .{rand_seeded.int(u32)});
    print("Seeded PRNG i32:       {}\n", .{rand_seeded.int(i32)});
    print("Seeded PRNG float:     {d}\n", .{rand_seeded.float(f64)});

    var data = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 20, 30, 40, 50 };
    rand_seeded.shuffle(u8, &data);
    print("Shuffled data:         {any}\n", .{data});

    // --- Fixed-seed PRNG (reproducible) ---
    // Seeding with a constant produces the same sequence every run.
    // Use this for debugging, simulations or procedural generation
    // where reproducibility matters.
    var fixed_prng = std.Random.DefaultPrng.init(0);
    const rand_fixed = fixed_prng.random();

    print("Fixed-seed float:      {d}\n", .{rand_fixed.float(f32)});
    print("Fixed-seed boolean:    {}\n", .{rand_fixed.boolean()});
    print("Fixed-seed u8:         {}\n", .{rand_fixed.int(u8)});
    print(
        "Fixed-seed u8 [0,255]: {}\n",
        .{rand_fixed.intRangeAtMost(u8, 0, 255)},
    );
}
