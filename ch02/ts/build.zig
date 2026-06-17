const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Fetch the tsdist package
    const tsdist_dep = b.dependency("tsdist", .{
        .target = target,
        .optimize = optimize,
    });

    // Create root module for your executable
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add tsdist as import (matches root module name in tsdist-zig: "distances")
    exe_mod.addImport("distances", tsdist_dep.module("distances"));

    // Build the executable
    const exe = b.addExecutable(.{
        .name = "ts",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
