const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Main executable ───────────────────────────────────────────────────
    const exe = b.addExecutable(.{
        .name = "zcache",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    // Zig 0.16: if (b.args) |args| run_cmd.addArgs(args);
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run the zcache server");
    run_step.dependOn(&run_cmd.step);

    // ── Benchmark client ──────────────────────────────────────────────────
    // Built in ReleaseFast so timings reflect production performance,
    // not debug overhead.
    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    b.installArtifact(bench_exe);
    const bench_step = b.step(
        "bench",
        "Build the benchmark client (run: ./zig-out/bin/bench)",
    );
    bench_step.dependOn(&bench_exe.step);

    // ── Interactive CLI client ─────────────────────────────────────────────
    // We only install the binary — no Run step — because zig build treats any
    // non-zero exit code from a Run step as a build failure. Run the CLI
    // directly: ./zig-out/bin/zcache_cli <command> [args]
    const cli_exe = b.addExecutable(.{
        .name = "zcache_cli",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zcache_cli.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(cli_exe);

    const cli_step = b.step(
        "cli",
        "Build the zcache CLI (run: ./zig-out/bin/zcache_cli)",
    );
    cli_step.dependOn(&cli_exe.step);

    // ── ZEMP test client ──────────────────────────────────────────────────
    const client_exe = b.addExecutable(.{
        .name = "zemp_client",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zemp_client.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(client_exe);

    const client_run = b.addRunArtifact(client_exe);
    client_run.step.dependOn(b.getInstallStep());
    // Zig 0.16: if (b.args) |args| client_run.addArgs(args);
    client_run.addPassthruArgs();
    const client_step = b.step("client", "Run the ZEMP test client");
    client_step.dependOn(&client_run.step);

    // ── Unit tests (one test binary per module) ───────────────────────────
    const test_step = b.step("test", "Run all unit tests");
    for ([_][]const u8{ "src/cache.zig", "src/protocol.zig" }) |src| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(src),
                .target = target,
                .optimize = optimize,
            }),
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}
