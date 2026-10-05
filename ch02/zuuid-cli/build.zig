const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 1. Get the dependency defined in build.zig.zon
    const zuuid_dep = b.dependency("zuuidcli", .{
        .target = target,
        .optimize = optimize,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // 3. Import the module into our app
    exe_mod.addImport("zuuid", zuuid_dep.module("zuuid"));

    const exe = b.addExecutable(.{
        .name = "zuuid-cli",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    // Zig 0.16: if (b.args) |args| { run_cmd.addArgs(args); }
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
